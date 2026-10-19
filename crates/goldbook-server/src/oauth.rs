use crate::{App, Error, Input, Reply, Result, db, hash, header, now};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde_json::{Value, json};
use std::{io::Read, time::Duration};

const PREFIX: &str = "/api/auth/battlenet/";
const PAIR_SECONDS: i64 = 600;
const SESSION_SECONDS: i64 = 30 * 86400;
// The browser's half of a sign-in's state: the app's pairing, or the website's.
const APP_CSRF: &str = "gb_bnet_csrf";
const WEB_CSRF: &str = "gb_bnet_web_csrf";

#[derive(Clone)]
pub struct BattleNetConfig {
    pub client_id: String,
    pub client_secret: String,
    pub public_url: String,
    // Tests may inject a local provider; environment configuration always uses Battle.net.
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    pub userinfo_endpoint: String,
}
impl BattleNetConfig {
    pub fn new(client_id: String, client_secret: String, public_url: String) -> Self {
        Self {
            client_id,
            client_secret,
            public_url,
            authorization_endpoint: "https://oauth.battle.net/authorize".into(),
            token_endpoint: "https://oauth.battle.net/token".into(),
            userinfo_endpoint: "https://oauth.battle.net/userinfo".into(),
        }
    }
    pub(crate) fn from_env() -> anyhow::Result<Option<Self>> {
        let values = [
            "BNET_CLIENT_ID",
            "BNET_CLIENT_SECRET",
            "GOLDBOOK_PUBLIC_URL",
        ]
        .map(|name| std::env::var(name).unwrap_or_default());
        if values.iter().all(String::is_empty) {
            return Ok(None);
        }
        anyhow::ensure!(
            values.iter().all(|value| !value.trim().is_empty()),
            "BNET_CLIENT_ID, BNET_CLIENT_SECRET, and GOLDBOOK_PUBLIC_URL must all be configured"
        );
        let [id, secret, public] = values;
        let config = Self::new(id, secret, public);
        config.validate()?;
        Ok(Some(config))
    }
    pub(crate) fn validate(&self) -> anyhow::Result<()> {
        let url = url::Url::parse(&self.public_url)
            .map_err(|_| anyhow::anyhow!("invalid GOLDBOOK_PUBLIC_URL"))?;
        let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
        anyhow::ensure!(
            url.host_str().is_some()
                && (url.scheme() == "https" || (local && url.scheme() == "http"))
                && url.username().is_empty()
                && url.password().is_none()
                && url.query().is_none()
                && url.fragment().is_none(),
            "GOLDBOOK_PUBLIC_URL must be an HTTPS server URL (HTTP is permitted only on localhost)"
        );
        anyhow::ensure!(
            !self.client_id.trim().is_empty() && !self.client_secret.trim().is_empty(),
            "Battle.net credentials must both be configured"
        );
        Ok(())
    }
    fn endpoint(&self, suffix: &str) -> String {
        format!("{}{PREFIX}{suffix}", self.public_url.trim_end_matches('/'))
    }
    fn cookie(&self, name: &str, value: &str, age: i64) -> String {
        let path = url::Url::parse(&self.public_url)
            .expect("validated public URL")
            .path()
            .trim_end_matches('/')
            .to_owned();
        format!(
            "{name}={value}; Path={path}{PREFIX}; Max-Age={age}; HttpOnly; SameSite=Lax{}",
            if self.public_url.starts_with("https://") {
                "; Secure"
            } else {
                ""
            }
        )
    }
}
fn secret() -> String {
    URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>())
}
fn no_store(mut reply: Reply) -> Reply {
    reply.headers.push(("cache-control", "no-store".into()));
    if !reply
        .headers
        .iter()
        .any(|(name, _)| *name == "referrer-policy")
    {
        reply
            .headers
            .push(("referrer-policy", "no-referrer".into()));
    }
    reply
}
fn failure(status: u16, text: &str) -> Error {
    Error::new(status, text)
}
fn valid_secret(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn csrf<'a>(input: &'a Input, name: &str) -> Option<&'a str> {
    header(&input.headers, "cookie")
        .split(';')
        .find_map(|part| part.trim().strip_prefix(name)?.strip_prefix('='))
        .filter(|value| valid_secret(value))
}

pub(super) fn respond(input: &Input, app: &App) -> Result<Reply> {
    if input.method == "GET" && input.path == format!("{PREFIX}status") {
        // `enabled` is for the app; `web` tells the website it can sign in.
        let enabled = app.config.battlenet.is_some();
        return Ok(no_store(Reply::json(
            json!({"enabled":enabled,"web":enabled}),
        )));
    }
    let config = app
        .config
        .battlenet
        .as_ref()
        .ok_or_else(|| failure(404, "Battle.net sign-in is not configured"))?;
    let mut db = db::connect(&app.config.database)?;
    let reply = match (
        input.method.as_str(),
        input.path.strip_prefix(PREFIX).unwrap_or(""),
    ) {
        ("POST", "start") => start(input, app, config, &mut db),
        ("GET", "authorize") => confirmation(input, &db),
        ("POST", "authorize") => authorize(input, app, config, &db),
        ("GET", "web/start") => web_start(input, app, config, &mut db),
        ("GET", "callback") => callback(input, config, &mut db),
        ("POST", "poll") => poll(input, &mut db),
        _ => Err(failure(404, "not found")),
    };
    // Failures must not be cached either; never include provider response content.
    Ok(no_store(reply.unwrap_or_else(Reply::error)))
}
fn start(input: &Input, app: &App, config: &BattleNetConfig, db: &mut Connection) -> Result<Reply> {
    if !input
        .json()?
        .as_object()
        .is_some_and(|object| object.is_empty())
    {
        return Err(failure(400, "the body must be an empty JSON object"));
    }
    if app.oauth_starts.lock().unwrap().begin(
        None,
        Some(input.client.as_deref().unwrap_or("unknown")),
        now(),
    ) > 0
    {
        return Err(failure(429, "too many sign-in attempts, try again later"));
    }
    let request = secret();
    let poll = secret();
    let alphabet = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let code: String = rand::random::<[u8; 8]>()
        .iter()
        .map(|byte| alphabet[usize::from(*byte) % alphabet.len()] as char)
        .collect();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute(
        "DELETE FROM battlenet_pairings WHERE expires_at<=?1",
        [now()],
    )?;
    tx.execute(
        "DELETE FROM battlenet_sessions WHERE expires_at<=?1",
        [now()],
    )?;
    tx.execute(
        "INSERT INTO battlenet_pairings(request_id,poll_hash,expires_at,user_code_hash) VALUES (?1,?2,?3,?4)",
        params![request, hash(&poll), now() + PAIR_SECONDS, hash(&code)],
    )?;
    tx.commit()?;
    let mut url = url::Url::parse(&config.endpoint("authorize")).expect("validated URL");
    url.query_pairs_mut().append_pair("request", &request);
    Ok(Reply::json(
        json!({"authorizationUrl":url.as_str(),"pollToken":poll,"userCode":code,"expiresIn":PAIR_SECONDS,"interval":3}),
    ))
}
fn html(body: String) -> Reply {
    Reply {
        status: 200,
        body: body.into_bytes(),
        content_type: "text/html; charset=utf-8",
        headers: vec![],
    }
}
fn confirmation(input: &Input, db: &Connection) -> Result<Reply> {
    let request = input
        .query
        .get("request")
        .filter(|value| valid_secret(value))
        .ok_or_else(|| failure(400, "invalid sign-in request"))?;
    let exists: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM battlenet_pairings WHERE request_id=?1 AND expires_at>?2 AND state_hash IS NULL)",params![request,now()],|row|row.get(0))?;
    if !exists {
        return Err(failure(
            400,
            "sign-in request expired or already opened; start again in Goldbook",
        ));
    }
    let mut page = html(format!(
        r#"<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Connect Goldbook</title><main><h1>Connect Goldbook to Battle.net</h1><p>Only continue if you started sign-in in Goldbook.</p><p>Enter the eight-character code shown in the Goldbook app. Never enter a code sent by someone else.</p><form method="post" action="authorize"><input type="hidden" name="request" value="{request}"><label>Goldbook code <input name="userCode" required minlength="8" maxlength="8" autocomplete="off" spellcheck="false" pattern="[A-Z2-9]{{8}}"></label><button type="submit">Continue to Battle.net</button></form></main></html>"#
    ));
    // Browsers send the form's Origin only under a referrer policy that
    // allows it. Its redirect to Battle.net continues through regional login
    // hosts, and form-action would have to name every one.
    page.headers.push(("referrer-policy", "same-origin".into()));
    page.headers.push((
        "content-security-policy",
        crate::CSP.replace("; form-action 'self'", ""),
    ));
    Ok(page)
}
fn authorize(input: &Input, app: &App, config: &BattleNetConfig, db: &Connection) -> Result<Reply> {
    let origin = url::Url::parse(&config.public_url)
        .expect("validated URL")
        .origin()
        .ascii_serialization();
    if header(&input.headers, "origin") != origin {
        return Err(failure(
            403,
            "sign-in confirmation must come from this Goldbook server",
        ));
    }
    if app.oauth_codes.lock().unwrap().begin(
        None,
        Some(input.client.as_deref().unwrap_or("unknown")),
        now(),
    ) > 0
    {
        return Err(failure(
            429,
            "too many confirmation attempts, try again later",
        ));
    }
    let fields: Vec<_> = url::form_urlencoded::parse(&input.body).collect();
    if fields.len() != 2
        || fields.iter().filter(|(key, _)| key == "request").count() != 1
        || fields.iter().filter(|(key, _)| key == "userCode").count() != 1
    {
        return Err(failure(400, "provide the Goldbook request and code"));
    }
    let request = fields
        .iter()
        .find(|(key, _)| key == "request")
        .unwrap()
        .1
        .as_ref();
    let code = fields
        .iter()
        .find(|(key, _)| key == "userCode")
        .unwrap()
        .1
        .as_ref();
    if !valid_secret(request) || code.len() != 8 {
        return Err(failure(400, "invalid Goldbook confirmation code"));
    }
    let state = secret();
    let csrf = secret();
    let updated = db.execute("UPDATE battlenet_pairings SET state_hash=?1,csrf_hash=?2 WHERE request_id=?3 AND expires_at>?4 AND state_hash IS NULL AND user_code_hash=?5", params![hash(&state),hash(&csrf),request,now(),hash(code)])?;
    if updated != 1 {
        return Err(failure(
            400,
            "sign-in request expired or already opened; start again in Goldbook",
        ));
    }
    to_provider(config, &state, config.cookie(APP_CSRF, &csrf, PAIR_SECONDS))
}
// Sends the browser on to Battle.net with the sign-in's state, and keeps the
// browser's half of it in `cookie`.
fn to_provider(config: &BattleNetConfig, state: &str, cookie: String) -> Result<Reply> {
    let mut url = url::Url::parse(&config.authorization_endpoint)
        .map_err(|_| failure(500, "sign-in configuration error"))?;
    url.query_pairs_mut()
        .append_pair("client_id", &config.client_id)
        .append_pair("response_type", "code")
        .append_pair("scope", "openid")
        .append_pair("redirect_uri", &config.endpoint("callback"))
        .append_pair("state", state);
    let mut reply = Reply::json(json!({}));
    reply.status = 303;
    reply.headers.push(("location", url.into()));
    reply.headers.push(("set-cookie", cookie));
    Ok(reply)
}
fn web_start(
    input: &Input,
    app: &App,
    config: &BattleNetConfig,
    db: &mut Connection,
) -> Result<Reply> {
    // The cookie belongs to the host the browser asked, but Battle.net returns
    // to the public URL's host, so the sign-in starts there.
    let public = url::Url::parse(&config.public_url).expect("validated URL");
    let asked = url::Url::parse(&format!("http://{}", header(&input.headers, "host"))).ok();
    if asked.is_some_and(|asked| asked.host_str() != public.host_str()) {
        let mut reply = Reply::json(json!({}));
        reply.status = 303;
        reply
            .headers
            .push(("location", config.endpoint("web/start")));
        return Ok(reply);
    }
    if app.web_starts.lock().unwrap().begin(
        None,
        Some(input.client.as_deref().unwrap_or("unknown")),
        now(),
    ) > 0
    {
        return Err(failure(429, "too many sign-in attempts, try again later"));
    }
    let state = secret();
    let csrf = secret();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute(
        "DELETE FROM battlenet_web_logins WHERE expires_at<=?1",
        [now()],
    )?;
    tx.execute(
        "INSERT INTO battlenet_web_logins(state_hash,csrf_hash,expires_at) VALUES (?1,?2,?3)",
        params![hash(&state), hash(&csrf), now() + PAIR_SECONDS],
    )?;
    tx.commit()?;
    to_provider(config, &state, config.cookie(WEB_CSRF, &csrf, PAIR_SECONDS))
}
// The player Battle.net verified, from the code it sent the browser back with.
fn verified_identity(input: &Input, config: &BattleNetConfig) -> Result<String> {
    if input.query.contains_key("error") {
        return Err(failure(401, "Battle.net sign-in was cancelled"));
    }
    let code = input
        .query
        .get("code")
        .filter(|value| !value.is_empty() && value.len() <= 4096)
        .ok_or_else(|| failure(400, "missing sign-in code"))?;
    provider_identity(config, code)
}
// Battle.net sends both the app's and the website's sign-ins back here, so the
// portal keeps one redirect URL. The state says which one it is.
fn callback(input: &Input, config: &BattleNetConfig, db: &mut Connection) -> Result<Reply> {
    let state = input
        .query
        .get("state")
        .filter(|value| valid_secret(value))
        .ok_or_else(|| failure(400, "invalid sign-in state"))?;
    let web: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM battlenet_web_logins WHERE state_hash=?1)",
        [hash(state)],
        |row| row.get(0),
    )?;
    if web {
        return web_callback(input, config, db, state);
    }
    let csrf = csrf(input, APP_CSRF)
        .ok_or_else(|| failure(400, "sign-in cookie missing; start again in Goldbook"))?;
    let request: Option<String> = db.query_row("SELECT request_id FROM battlenet_pairings WHERE state_hash=?1 AND csrf_hash=?2 AND expires_at>?3 AND consumed_at IS NULL",params![hash(state),hash(csrf),now()],|row| row.get(0)).optional()?;
    let request = request.ok_or_else(|| failure(400, "sign-in state expired or already used"))?;
    if db.execute("UPDATE battlenet_pairings SET consumed_at=?1 WHERE request_id=?2 AND consumed_at IS NULL AND expires_at>?1", params![now(),request])? != 1 {
        return Err(failure(400,"sign-in state expired or already used"));
    }
    let identity = (|| -> Result<String> {
        let identity = verified_identity(input, config)?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            "INSERT INTO battlenet_identities(identity_hash) VALUES (?1) ON CONFLICT DO NOTHING",
            [&identity],
        )?;
        check_player(&tx, &identity)?;
        tx.execute(
            "UPDATE battlenet_pairings SET identity_hash=?1 WHERE request_id=?2",
            params![identity, request],
        )?;
        tx.commit()?;
        Ok(identity)
    })();
    if let Err(error) = identity {
        db.execute(
            "UPDATE battlenet_pairings SET failed=1 WHERE request_id=?1",
            [&request],
        )?;
        return Err(error);
    }
    let mut reply = html(r#"<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Goldbook connected</title><main><h1>Battle.net connected.</h1><p>Return to Goldbook. You can close this tab.</p></main></html>"#.into());
    reply
        .headers
        .push(("set-cookie", config.cookie(APP_CSRF, "", 0)));
    Ok(reply)
}
// Signs the browser in to the website as the player, and sends it on to Gold.
fn web_callback(
    input: &Input,
    config: &BattleNetConfig,
    db: &mut Connection,
    state: &str,
) -> Result<Reply> {
    let csrf = csrf(input, WEB_CSRF)
        .ok_or_else(|| failure(400, "sign-in cookie missing; sign in again"))?;
    if db.execute("UPDATE battlenet_web_logins SET consumed_at=?1 WHERE state_hash=?2 AND csrf_hash=?3 AND expires_at>?1 AND consumed_at IS NULL", params![now(),hash(state),hash(csrf)])? != 1 {
        return Err(failure(400, "sign-in state expired or already used"));
    }
    let identity = verified_identity(input, config)?;
    let token = secret();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute(
        "INSERT INTO battlenet_identities(identity_hash) VALUES (?1) ON CONFLICT DO NOTHING",
        [&identity],
    )?;
    check_player(&tx, &identity)?;
    tx.execute(
        "DELETE FROM battlenet_web_sessions WHERE expires_at<=?1",
        [now()],
    )?;
    tx.execute(
        "INSERT INTO battlenet_web_sessions(token_hash,identity_hash,expires_at) VALUES (?1,?2,?3)",
        params![hash(&token), identity, now() + SESSION_SECONDS],
    )?;
    tx.commit()?;
    let mut reply = Reply::json(json!({}));
    reply.status = 303;
    reply.headers.push((
        "location",
        format!("{}/#gold", config.public_url.trim_end_matches('/')),
    ));
    reply
        .headers
        .push(crate::routes::cookie(input, &token, SESSION_SECONDS));
    reply
        .headers
        .push(("set-cookie", config.cookie(WEB_CSRF, "", 0)));
    Ok(reply)
}
fn provider_json(response: reqwest::blocking::Response) -> Result<Value> {
    if !response.status().is_success() {
        return Err(failure(
            502,
            "Battle.net could not complete sign-in; start again in Goldbook",
        ));
    }
    let mut bytes = Vec::new();
    response
        .take(65537)
        .read_to_end(&mut bytes)
        .map_err(|_| failure(502, "Battle.net sign-in response failed"))?;
    if bytes.len() > 65536 {
        return Err(failure(502, "Battle.net sign-in response failed"));
    }
    serde_json::from_slice(&bytes).map_err(|_| failure(502, "Battle.net sign-in response failed"))
}
fn provider_identity(config: &BattleNetConfig, code: &str) -> Result<String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| failure(502, "Battle.net connection failed"))?;
    let token = provider_json(
        client
            .post(&config.token_endpoint)
            .basic_auth(&config.client_id, Some(&config.client_secret))
            .form(&[
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", &config.endpoint("callback")),
            ])
            .send()
            .map_err(|_| failure(502, "Battle.net connection failed"))?,
    )?;
    let access = token["access_token"]
        .as_str()
        .filter(|value| !value.is_empty() && value.len() <= 16384)
        .ok_or_else(|| failure(502, "Battle.net sign-in response failed"))?;
    let user = provider_json(
        client
            .get(&config.userinfo_endpoint)
            .bearer_auth(access)
            .send()
            .map_err(|_| failure(502, "Battle.net connection failed"))?,
    )?;
    let subject = user["sub"]
        .as_str()
        .filter(|value| !value.is_empty() && value.len() <= 256)
        .ok_or_else(|| failure(502, "Battle.net did not verify an account"))?;
    Ok(hash(&format!("battlenet:{subject}")))
}
fn poll(input: &Input, db: &mut Connection) -> Result<Reply> {
    let body = input.json()?;
    let token = body["pollToken"]
        .as_str()
        .filter(|value| valid_secret(value))
        .ok_or_else(|| failure(401, "invalid sign-in request"))?;
    if body.as_object().is_none_or(|object| object.len() != 1) {
        return Err(failure(400, "provide only the poll token"));
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    struct Pairing {
        request: String,
        identity: Option<String>,
        failed: bool,
        polled: Option<i64>,
        last_poll: Option<i64>,
    }
    let pair: Option<Pairing> = tx.query_row(
        "SELECT request_id,identity_hash,failed,polled_at,last_poll_at FROM battlenet_pairings WHERE poll_hash=?1 AND expires_at>?2",
        params![hash(token), now()],
        |row| Ok(Pairing { request: row.get(0)?, identity: row.get(1)?, failed: row.get(2)?, polled: row.get(3)?, last_poll: row.get(4)? }),
    ).optional()?;
    let Pairing {
        request,
        identity,
        failed,
        polled,
        last_poll,
    } = pair.ok_or_else(|| failure(401, "sign-in request expired; start again"))?;
    if failed || polled.is_some() {
        return Err(failure(
            401,
            "sign-in request failed or already used; start again",
        ));
    }
    if last_poll.is_some_and(|last| now() - last < 3) {
        return Err(failure(429, "wait before checking sign-in again"));
    }
    tx.execute(
        "UPDATE battlenet_pairings SET last_poll_at=?1 WHERE request_id=?2",
        params![now(), request],
    )?;
    let Some(identity) = identity else {
        tx.commit()?;
        let mut reply = Reply::json(json!({"status":"pending"}));
        reply.status = 202;
        return Ok(reply);
    };
    check_player(&tx, &identity)?;
    let session = format!("bne_{}", secret());
    tx.execute(
        "INSERT INTO battlenet_sessions(token_hash,identity_hash,expires_at) VALUES (?1,?2,?3)",
        params![hash(&session), identity, now() + SESSION_SECONDS],
    )?;
    tx.execute(
        "UPDATE battlenet_pairings SET polled_at=?1 WHERE request_id=?2",
        params![now(), request],
    )?;
    tx.commit()?;
    Ok(Reply::json(json!({"sessionToken":session})))
}
fn check_player(db: &Connection, identity: &str) -> Result<()> {
    let blocked: bool = db.query_row(
        "SELECT blocked_at IS NOT NULL FROM battlenet_identities WHERE identity_hash=?1",
        [identity],
        |row| row.get(0),
    )?;
    if blocked {
        return Err(failure(403, "this player is blocked"));
    }
    Ok(())
}
pub(super) fn enrollment_identity(
    input: &Input,
    app: &App,
    db: &Connection,
) -> Result<Option<String>> {
    if app.config.battlenet.is_none() {
        return Ok(None);
    }
    let token = header(&input.headers, "authorization")
        .strip_prefix("Bearer ")
        .unwrap_or_default();
    let identity: Option<String> = db
        .query_row(
            "SELECT identity_hash FROM battlenet_sessions WHERE token_hash=?1 AND expires_at>?2",
            params![hash(token), now()],
            |row| row.get(0),
        )
        .optional()?;
    let identity = identity.ok_or_else(|| failure(401, "Battle.net sign-in required"))?;
    check_player(db, &identity)?;
    Ok(Some(identity))
}
pub(super) fn authorize_upload(db: &Connection, fingerprint: &str, app: &App) -> Result<()> {
    let identity: Option<String> = db.query_row(
        "SELECT battlenet_identity FROM upload_identities WHERE fingerprint=?1",
        [fingerprint],
        |row| row.get(0),
    )?;
    if let Some(identity) = identity {
        check_player(db, &identity)?;
    } else if app.config.battlenet.is_some() {
        return Err(failure(401, "Battle.net sign-in required"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn public_urls_require_https_and_do_not_embed_credentials_or_callback_queries() {
        for public in [
            "http://gold.example/goldbook",
            "https://user:secret@gold.example",
            "https://gold.example?q=value",
            "https://gold.example/#fragment",
            "file:///tmp/goldbook",
        ] {
            assert!(
                BattleNetConfig::new("client".into(), "private-secret".into(), public.into())
                    .validate()
                    .is_err()
            );
        }
        for public in [
            "https://gold.example/goldbook",
            "http://127.0.0.1:8787/goldbook",
            "http://localhost:8787",
        ] {
            BattleNetConfig::new("client".into(), "private-secret".into(), public.into())
                .validate()
                .unwrap();
        }
    }
}
