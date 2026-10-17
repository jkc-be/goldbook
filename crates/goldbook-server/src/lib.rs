mod auth;
pub mod db;
mod oauth;
mod routes;
pub use oauth::BattleNetConfig;

use auth::{LoginLimits, Network};
use axum::{
    Router,
    body::{Body, to_bytes},
    extract::{ConnectInfo, Request, State},
    http::{HeaderMap, Method},
    response::Response,
};
use rusqlite::OptionalExtension;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};
use subtle::ConstantTimeEq;

const MAX_BODY: usize = 20 * 1024 * 1024;
const MAX_LOGIN_BODY: usize = 4096;
const SESSION_SECONDS: i64 = 30 * 86400;

#[derive(Clone)]
pub struct Config {
    pub database: PathBuf,
    pub upload_token: String,
    pub self_registration: bool,
    pub battlenet: Option<BattleNetConfig>,
    pub web_dir: Option<PathBuf>,
    pub trusted_proxy: String,
    pub host: String,
    pub port: u16,
}
impl Config {
    pub fn new(database: impl Into<PathBuf>, upload_token: impl Into<String>) -> Self {
        Self {
            database: database.into(),
            upload_token: upload_token.into(),
            self_registration: false,
            battlenet: None,
            web_dir: None,
            trusted_proxy: String::new(),
            host: "127.0.0.1".into(),
            port: 8787,
        }
    }
    pub fn from_env() -> anyhow::Result<Self> {
        let mut c = Self::new(
            std::env::var("DATABASE").unwrap_or_else(|_| "data/goldbook.sqlite".into()),
            std::env::var("UPLOAD_TOKEN").unwrap_or_default(),
        );
        c.self_registration = std::env::var("SELF_REGISTRATION")
            .map(|value| value.parse::<bool>())
            .unwrap_or(Ok(false))?;
        c.battlenet = BattleNetConfig::from_env()?;
        c.host = std::env::var("HOST").unwrap_or(c.host);
        c.port = std::env::var("PORT")
            .map(|p| p.parse())
            .unwrap_or(Ok(c.port))?;
        c.web_dir = std::env::var_os("WEB_DIR").map(PathBuf::from);
        c.trusted_proxy = std::env::var("TRUSTED_PROXY").unwrap_or_default();
        Ok(c)
    }
}
struct App {
    config: Config,
    tokens: Vec<Vec<u8>>,
    proxies: Vec<Network>,
    logins: Mutex<LoginLimits>,
    registrations: Mutex<LoginLimits>,
    oauth_starts: Mutex<LoginLimits>,
    oauth_codes: Mutex<LoginLimits>,
}

pub fn router(config: Config) -> anyhow::Result<Router> {
    if let Some(battlenet) = &config.battlenet {
        battlenet.validate()?;
    }
    db::migrate(&mut db::connect(&config.database)?)?;
    let proxies = split(&config.trusted_proxy)
        .map(Network::parse)
        .collect::<anyhow::Result<Vec<_>>>()?;
    let tokens = split(&config.upload_token)
        .map(|t| format!("Bearer {t}").into_bytes())
        .collect();
    let state = Arc::new(App {
        config,
        tokens,
        proxies,
        logins: Mutex::new(LoginLimits::default()),
        registrations: Mutex::new(LoginLimits::default()),
        oauth_starts: Mutex::new(LoginLimits::default()),
        oauth_codes: Mutex::new(LoginLimits::default()),
    });
    let updates = state
        .config
        .database
        .parent()
        .unwrap_or(Path::new("."))
        .join("updates");
    Ok(Router::new()
        .nest_service("/updates", tower_http::services::ServeDir::new(updates))
        .fallback(handle)
        .with_state(state))
}
fn split(s: &str) -> impl Iterator<Item = &str> {
    s.split(',').map(str::trim).filter(|s| !s.is_empty())
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn hash(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
}
fn header<'a>(headers: &'a HeaderMap, name: &str) -> &'a str {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
}

struct Input {
    method: Method,
    path: String,
    query: HashMap<String, String>,
    headers: HeaderMap,
    body: Vec<u8>,
    client: Option<String>,
    secure: bool,
}
impl Input {
    fn cookie(&self) -> &str {
        header(&self.headers, "cookie")
            .split(';')
            .find_map(|p| {
                let (name, value) = p.trim().split_once('=')?;
                (name.trim() == "goldbook_session").then_some(value.trim())
            })
            .unwrap_or("")
    }
    fn json(&self) -> Result<Value> {
        parse_json(&self.body, false)
            .map(|(v, _)| v)
            .map_err(|_| Error::new(400, "the body must be JSON"))
    }
    fn upload<T: serde::Serialize + serde::de::DeserializeOwned>(
        &self,
        parse: impl FnOnce(&Value) -> std::result::Result<T, String>,
    ) -> Result<T> {
        let (value, repaired) =
            parse_json(&self.body, false).map_err(|_| Error::new(400, "the body must be JSON"))?;
        let parsed = parse(&value).map_err(|e| Error::new(400, e))?;
        if !repaired {
            return Ok(parsed);
        }
        // Validate each lone UTF-16 unit at its original length before the
        // storage conversion expands it into three replacement characters.
        let (stored, _) =
            parse_json(&self.body, true).map_err(|_| Error::new(400, "the body must be JSON"))?;
        let mut validated =
            serde_json::to_value(parsed).map_err(|e| Error::from(anyhow::Error::from(e)))?;
        restore_strings(&mut validated, &stored);
        serde_json::from_value(validated).map_err(|e| Error::from(anyhow::Error::from(e)))
    }
}
#[derive(Debug)]
struct Error {
    status: u16,
    message: String,
}
type Result<T> = std::result::Result<T, Error>;
impl Error {
    fn new(status: u16, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
}
impl From<rusqlite::Error> for Error {
    fn from(error: rusqlite::Error) -> Self {
        eprintln!("database request failed: {error}");
        Self::new(500, "internal error")
    }
}
impl From<anyhow::Error> for Error {
    fn from(error: anyhow::Error) -> Self {
        eprintln!("request failed: {error}");
        Self::new(500, "internal error")
    }
}
struct Reply {
    status: u16,
    body: Vec<u8>,
    content_type: &'static str,
    headers: Vec<(&'static str, String)>,
}
impl Reply {
    fn json(value: impl serde::Serialize) -> Self {
        Self {
            status: 200,
            body: serde_json::to_vec(&value).expect("JSON value"),
            content_type: "application/json",
            headers: vec![],
        }
    }
    fn error(error: Error) -> Self {
        let mut r = Self::json(json!({"error":error.message}));
        r.status = error.status;
        r
    }
    fn response(self, head: bool) -> Response {
        let mut response = Response::builder().status(self.status)
            .header("content-type",self.content_type).header("content-length",self.body.len())
            .header("x-content-type-options","nosniff").header("referrer-policy","same-origin")
            .header("content-security-policy","default-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
        for (name, value) in self.headers {
            response = response.header(name, value);
        }
        response
            .body(if head {
                Body::empty()
            } else {
                Body::from(self.body)
            })
            .expect("valid response")
    }
}
fn authorize(headers: &HeaderMap, state: &App) -> Result<Option<String>> {
    let given = headers
        .get("authorization")
        .map(|v| v.as_bytes())
        .unwrap_or_default();
    let mut matches = subtle::Choice::from(0);
    for token in &state.tokens {
        matches |= given.ct_eq(token);
    }
    if bool::from(matches) {
        return Ok(None);
    }
    if let Some(token) = std::str::from_utf8(given)
        .ok()
        .and_then(|value| value.strip_prefix("Bearer gb_"))
        .filter(|token| token.len() == 43)
    {
        let db = db::connect(&state.config.database)?;
        let status: Option<(bool, bool, String)> = db.query_row(
            "SELECT t.revoked_at IS NOT NULL,i.blocked_at IS NOT NULL,i.fingerprint FROM upload_tokens t JOIN upload_identities i ON i.fingerprint=t.fingerprint WHERE t.token_hash=?1",
            [hash(&format!("gb_{token}"))],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        ).optional()?;
        match status {
            Some((_, true, _)) => return Err(Error::new(403, "this account is blocked")),
            Some((true, false, _)) => return Err(Error::new(401, "invalid upload token")),
            Some((false, false, fingerprint)) => {
                oauth::authorize_upload(&db, &fingerprint, state)?;
                return Ok(Some(fingerprint));
            }
            None => {}
        }
    }
    if state.tokens.is_empty() && !state.config.self_registration {
        return Err(Error::new(503, "the upload token is not configured"));
    }
    Err(Error::new(401, "invalid upload token"))
}
fn require_json(content_type: &str, length: usize) -> Result<()> {
    if content_type != "application/json" && (!content_type.is_empty() || length > 0) {
        Err(Error::new(415, "the body must be JSON"))
    } else {
        Ok(())
    }
}
fn desktop_origin(origin: &str) -> bool {
    let Some(port) = origin.strip_prefix("http://127.0.0.1:") else {
        return false;
    };
    !port.is_empty()
        && port.len() <= 5
        && !port.starts_with('0')
        && port.bytes().all(|b| b.is_ascii_digit())
        && port.parse::<u16>().is_ok()
}
fn limit_error(limit: usize) -> Error {
    Error::new(
        413,
        if limit == MAX_BODY {
            "the body must be at most 20 MB"
        } else {
            "the body must be at most 4 KB"
        },
    )
}
async fn handle(State(state): State<Arc<App>>, request: Request) -> Response {
    let head = request.method() == Method::HEAD;
    let started = std::time::Instant::now();
    let (parts, body) = request.into_parts();
    let method = parts.method;
    let path = parts.uri.path().to_owned();
    let content_type = header(&parts.headers, "content-type")
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    let length = header(&parts.headers, "content-length")
        .parse::<usize>()
        .unwrap_or(0);
    let is_post = method == Method::POST;
    let upload = is_post
        && matches!(
            path.as_str(),
            "/api/scans" | "/api/sellers" | "/api/sellers/batch" | "/api/account"
        );
    let login = is_post
        && matches!(
            path.as_str(),
            "/api/login"
                | "/api/logout"
                | "/api/desktop-login"
                | "/api/link"
                | "/api/installations"
                | "/api/auth/battlenet/start"
                | "/api/auth/battlenet/poll"
        );
    let login = login || (is_post && path == "/api/auth/battlenet/authorize");
    let maximum = if login { MAX_LOGIN_BODY } else { MAX_BODY };
    let upload_fingerprint = if upload {
        let auth_state = Arc::clone(&state);
        let auth_headers = parts.headers.clone();
        let authorization =
            tokio::task::spawn_blocking(move || authorize(&auth_headers, &auth_state))
                .await
                .unwrap_or_else(|_| Err(Error::new(500, "internal error")));
        match authorization {
            Ok(fingerprint) => fingerprint,
            Err(error) => {
                // Closing with an unread body can reset the proxy connection,
                // replacing this response with a 502. Keep draining bounded.
                let _ = to_bytes(body, MAX_BODY).await;
                return Reply::error(error).response(head);
            }
        }
    } else {
        None
    };
    let precheck = (|| -> Result<()> {
        if is_post
            && matches!(
                path.as_str(),
                "/api/account"
                    | "/api/login"
                    | "/api/logout"
                    | "/api/link"
                    | "/api/installations"
                    | "/api/auth/battlenet/start"
                    | "/api/auth/battlenet/poll"
            )
        {
            require_json(&content_type, length)?;
        }
        if is_post
            && path == "/api/auth/battlenet/authorize"
            && content_type != "application/x-www-form-urlencoded"
        {
            return Err(Error::new(415, "sign-in confirmation must be a form"));
        }
        if is_post && path == "/api/desktop-login" {
            if !desktop_origin(header(&parts.headers, "origin")) {
                return Err(Error::new(
                    403,
                    "desktop login must come from the Goldbook app",
                ));
            }
            if content_type != "application/x-www-form-urlencoded" {
                return Err(Error::new(415, "desktop login must be a form"));
            }
        }
        if (upload || login) && length > maximum {
            return Err(limit_error(maximum));
        }
        Ok(())
    })();
    if let Err(e) = precheck {
        return Reply::error(e).response(head);
    }
    let bytes = if upload || login {
        match to_bytes(body, maximum).await {
            Ok(b) => b.to_vec(),
            Err(_) => return Reply::error(limit_error(maximum)).response(head),
        }
    } else {
        vec![]
    };
    if is_post
        && matches!(
            path.as_str(),
            "/api/account"
                | "/api/login"
                | "/api/logout"
                | "/api/link"
                | "/api/installations"
                | "/api/auth/battlenet/start"
                | "/api/auth/battlenet/poll"
        )
        && let Err(e) = require_json(&content_type, bytes.len())
    {
        return Reply::error(e).response(head);
    }
    let sender = parts
        .extensions
        .get::<ConnectInfo<SocketAddr>>()
        .map(|c| c.0.ip().to_string())
        .unwrap_or_default();
    let client = auth::client_address(
        &sender,
        header(&parts.headers, "x-forwarded-for"),
        &state.proxies,
    );
    let secure = header(&parts.headers, "x-forwarded-proto")
        .split(',')
        .next()
        .unwrap_or("")
        .trim()
        == "https";
    let mut query = HashMap::new();
    for (k, v) in url::form_urlencoded::parse(parts.uri.query().unwrap_or("").as_bytes()) {
        query.entry(k.into_owned()).or_insert(v.into_owned());
    }
    let input = Input {
        method: method.clone(),
        path: path.clone(),
        query,
        headers: parts.headers,
        body: bytes,
        client,
        secure,
    };
    let reply = tokio::task::spawn_blocking(move || routes::respond(input, &state)).await;
    let reply = match reply {
        Ok(Ok(r)) => r,
        Ok(Err(e)) => Reply::error(e),
        Err(e) => {
            eprintln!("request task failed: {e}");
            Reply::error(Error::new(500, "internal error"))
        }
    };
    eprintln!(
        "{method} {path} {} {:.1}ms{}",
        reply.status,
        started.elapsed().as_secs_f64() * 1000.0,
        upload_fingerprint
            .map(|fingerprint| format!(" fingerprint={fingerprint}"))
            .unwrap_or_default()
    );
    reply.response(head)
}

// Python's original JSON parser accepts lone escaped UTF-16 surrogates. Its
// UTF-8 storage conversion replaces each of their three invalid bytes.
fn parse_json(body: &[u8], storage: bool) -> std::result::Result<(Value, bool), serde_json::Error> {
    let mut changed = false;
    fn code(bytes: &[u8]) -> Option<u16> {
        if bytes.len() < 6 || &bytes[..2] != b"\\u" {
            return None;
        }
        std::str::from_utf8(&bytes[2..6])
            .ok()
            .and_then(|s| u16::from_str_radix(s, 16).ok())
    }
    let mut repaired = Vec::with_capacity(body.len());
    let mut i = 0;
    while i < body.len() {
        if body[i] == b'\\' {
            if let Some(unit) = code(&body[i..]) {
                if (0xd800..=0xdbff).contains(&unit)
                    && code(&body[i + 6..]).is_some_and(|low| (0xdc00..=0xdfff).contains(&low))
                {
                    repaired.extend_from_slice(&body[i..i + 12]);
                    i += 12;
                    continue;
                }
                if (0xd800..=0xdfff).contains(&unit) {
                    repaired.extend_from_slice(if storage {
                        b"\\ufffd\\ufffd\\ufffd"
                    } else {
                        b"\\ufffd"
                    });
                    changed = true;
                    i += 6;
                    continue;
                }
            }
            if i + 1 < body.len() {
                repaired.extend_from_slice(&body[i..i + 2]);
                i += 2;
                continue;
            }
        }
        repaired.push(body[i]);
        i += 1;
    }
    serde_json::from_slice(&repaired).map(|v| (v, changed))
}

fn restore_strings(value: &mut Value, source: &Value) {
    match value {
        Value::String(s) => {
            if let Some(stored) = source.as_str() {
                *s = stored.into();
            }
        }
        Value::Array(values) => {
            for (i, value) in values.iter_mut().enumerate() {
                restore_strings(value, &source[i]);
            }
        }
        Value::Object(values) => {
            for (key, value) in values {
                restore_strings(value, &source[key]);
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod json_tests {
    use super::parse_json;
    use serde_json::json;

    #[test]
    fn repairs_only_lone_surrogates_and_preserves_paired_or_literal_escapes() {
        let raw = r#"["\ud800","\udc00","\ud83d\ude00","\\ud800","�"]"#.as_bytes();
        assert_eq!(
            parse_json(raw, true).unwrap().0,
            json!(["���", "���", "😀", r"\ud800", "�"])
        );
        assert_eq!(
            parse_json(raw, false).unwrap().0,
            json!(["�", "�", "😀", r"\ud800", "�"])
        );
        assert!(!parse_json(br#"["\\ud800"]"#, true).unwrap().1);
    }
}
