use axum::{
    Json, Router,
    body::{Body, to_bytes},
    extract::{ConnectInfo, Form},
    http::{HeaderMap, Request, StatusCode},
    routing::{get, post},
};
use goldbook_server::{BattleNetConfig, Config, db, router};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    net::SocketAddr,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};
use tower::ServiceExt;

struct Fixture {
    directory: PathBuf,
    app: Router,
    config: Config,
    provider: tokio::task::JoinHandle<()>,
    requests: Arc<AtomicUsize>,
}
impl Fixture {
    async fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let directory = std::env::temp_dir().join(format!(
            "goldbook-oauth-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let requests = Arc::new(AtomicUsize::new(0));
        let count = requests.clone();
        let provider_app=Router::new().route("/token",post(move |headers:HeaderMap,Form(body):Form<HashMap<String,String>>| {
            count.fetch_add(1,Ordering::Relaxed);
            async move {
                assert_eq!(headers["authorization"],"Basic Y2xpZW50OnRlc3Qtc2VjcmV0");
                assert_eq!(body["grant_type"],"authorization_code");
                assert_eq!(body["redirect_uri"],"https://gold.example/goldbook/api/auth/battlenet/callback");
                if body["code"]=="provider-failure" { (StatusCode::BAD_REQUEST,Json(json!({"error":"private-provider-detail"}))) }
                else { (StatusCode::OK,Json(json!({"access_token":body["code"],"token_type":"bearer"}))) }
            }
        })).route("/userinfo",get(|headers:HeaderMap| async move {
            let subject=if headers["authorization"]=="Bearer other-player" {"456"} else {"123"};
            Json(json!({"sub":subject,"id":subject.parse::<u64>().unwrap(),"battletag":"Private#1234"}))
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let provider =
            tokio::spawn(async move { axum::serve(listener, provider_app).await.unwrap() });
        let mut bnet = BattleNetConfig::new(
            "client".into(),
            "test-secret".into(),
            "https://gold.example/goldbook".into(),
        );
        bnet.authorization_endpoint = format!("{origin}/authorize");
        bnet.token_endpoint = format!("{origin}/token");
        bnet.userinfo_endpoint = format!("{origin}/userinfo");
        let mut config = Config::new(directory.join("goldbook.sqlite"), "admin-token");
        config.self_registration = true;
        config.battlenet = Some(bnet);
        let app = router(config.clone()).unwrap();
        Self {
            directory,
            app,
            config,
            provider,
            requests,
        }
    }
    fn database(&self) -> PathBuf {
        self.directory.join("goldbook.sqlite")
    }
    async fn begin(&self) -> (String, String, String) {
        let started = call(
            &self.app,
            "POST",
            "/api/auth/battlenet/start",
            json!({}),
            &[],
        )
        .await;
        assert_eq!(started.0, 200);
        assert_eq!(started.1["cache-control"], "no-store");
        let public_url = url::Url::parse(started.2["authorizationUrl"].as_str().unwrap()).unwrap();
        let target = format!(
            "/api/auth/battlenet/authorize?{}",
            public_url.query().unwrap()
        );
        let opened = call(&self.app, "GET", &target, Value::Null, &[]).await;
        assert_eq!(opened.0, 200);
        assert!(!opened.1.contains_key("location"));
        let page = opened.2.as_str().unwrap();
        assert!(page.contains("Only continue if you started sign-in in Goldbook."));
        assert!(!page.contains(started.2["userCode"].as_str().unwrap()));
        // Browsers enforce every copy of these headers, so each must be the only one.
        let only = |name| {
            let values: Vec<_> = opened.1.get_all(name).iter().collect();
            assert_eq!(values.len(), 1, "{name}");
            values[0].to_str().unwrap().to_owned()
        };
        assert_eq!(only("referrer-policy"), "same-origin");
        assert_eq!(
            only("content-security-policy"),
            "default-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'"
        );
        let request = public_url
            .query_pairs()
            .find(|(key, _)| key == "request")
            .unwrap()
            .1
            .into_owned();
        for origin in [None, Some("null"), Some("https://attacker.example")] {
            let mut headers = vec![("content-type", "application/x-www-form-urlencoded")];
            if let Some(origin) = origin {
                headers.push(("origin", origin));
            }
            let denied = call(
                &self.app,
                "POST",
                "/api/auth/battlenet/authorize",
                json!({"request":request,"userCode":started.2["userCode"]}),
                &headers,
            )
            .await;
            assert_eq!(denied.0, 403);
            assert!(!denied.1.contains_key("set-cookie"));
            assert!(!denied.1.contains_key("location"));
        }
        let wrong = call(
            &self.app,
            "POST",
            "/api/auth/battlenet/authorize",
            json!({"request":request,"userCode":"BADCODE2"}),
            &[
                ("content-type", "application/x-www-form-urlencoded"),
                ("origin", "https://gold.example"),
            ],
        )
        .await;
        assert_eq!(wrong.0, 400);
        let opened = call(
            &self.app,
            "POST",
            "/api/auth/battlenet/authorize",
            json!({"request":request,"userCode":started.2["userCode"]}),
            &[
                ("content-type", "application/x-www-form-urlencoded"),
                ("origin", "https://gold.example"),
            ],
        )
        .await;
        assert_eq!(opened.0, 303);
        let cookie = opened.1["set-cookie"].to_str().unwrap();
        assert!(cookie.contains("HttpOnly; SameSite=Lax; Secure"));
        assert!(cookie.contains("Path=/goldbook/api/auth/battlenet/"));
        let cookie = cookie.split(';').next().unwrap().to_owned();
        let provider = url::Url::parse(opened.1["location"].to_str().unwrap()).unwrap();
        let fields: HashMap<String, String> = provider.query_pairs().into_owned().collect();
        assert_eq!(fields["scope"], "openid");
        assert_eq!(fields["response_type"], "code");
        assert_ne!(fields["state"], started.2["pollToken"].as_str().unwrap());
        (
            started.2["pollToken"].as_str().unwrap().into(),
            fields["state"].clone(),
            cookie,
        )
    }
    async fn session(&self, code: &str) -> String {
        let (poll, state, cookie) = self.begin().await;
        assert_eq!(
            call(
                &self.app,
                "GET",
                &format!("/api/auth/battlenet/callback?state={state}&code={code}"),
                Value::Null,
                &[("cookie", &cookie)]
            )
            .await
            .0,
            200
        );
        let ready = call(
            &self.app,
            "POST",
            "/api/auth/battlenet/poll",
            json!({"pollToken":poll}),
            &[],
        )
        .await;
        assert_eq!(ready.0, 200);
        ready.2["sessionToken"].as_str().unwrap().into()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.provider.abort();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}
async fn call(
    app: &Router,
    method: &str,
    path: &str,
    body: Value,
    headers: &[(&str, &str)],
) -> (u16, HeaderMap, Value) {
    let mut request = Request::builder().method(method).uri(path);
    for (key, value) in headers {
        request = request.header(*key, *value);
    }
    let bytes = if method == "POST" {
        if headers.iter().any(|(key, value)| {
            *key == "content-type" && *value == "application/x-www-form-urlencoded"
        }) {
            let mut form = url::form_urlencoded::Serializer::new(String::new());
            for (key, value) in body.as_object().unwrap() {
                form.append_pair(key, value.as_str().unwrap());
            }
            form.finish().into_bytes()
        } else {
            request = request.header("content-type", "application/json");
            serde_json::to_vec(&body).unwrap()
        }
    } else {
        vec![]
    };
    let mut request = request.body(Body::from(bytes)).unwrap();
    request.extensions_mut().insert(ConnectInfo(
        "203.0.113.8:1234".parse::<SocketAddr>().unwrap(),
    ));
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    let bytes = to_bytes(response.into_body(), 65536).await.unwrap();
    (
        status,
        headers,
        serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| Value::String(String::from_utf8(bytes.to_vec()).unwrap())),
    )
}
fn registration(digit: &str) -> Value {
    json!({"fingerprint":digit.repeat(64),"fingerprintVersion":1})
}

#[tokio::test]
async fn browser_state_cookie_expiry_replay_and_poll_secret_are_enforced() {
    let f = Fixture::new().await;
    assert_eq!(
        call(
            &f.app,
            "GET",
            "/api/auth/battlenet/status",
            Value::Null,
            &[]
        )
        .await
        .2,
        json!({"enabled":true})
    );
    let (poll, state, cookie) = f.begin().await;
    let callback = format!("/api/auth/battlenet/callback?state={state}&code=approved");
    assert_eq!(
        call(&f.app, "GET", &callback, Value::Null, &[]).await.0,
        400
    );
    assert_eq!(
        call(
            &f.app,
            "GET",
            &callback,
            Value::Null,
            &[(
                "cookie",
                "gb_bnet_csrf=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            )]
        )
        .await
        .0,
        400
    );
    assert_eq!(call(&f.app,"GET","/api/auth/battlenet/callback?state=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&code=approved",Value::Null,&[("cookie",&cookie)]).await.0,400);
    assert_eq!(f.requests.load(Ordering::Relaxed), 0);
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/auth/battlenet/poll",
            json!({"pollToken":state}),
            &[]
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &f.app,
            "GET",
            &callback,
            Value::Null,
            &[("cookie", &cookie)]
        )
        .await
        .0,
        200
    );
    assert_eq!(
        call(
            &f.app,
            "GET",
            &callback,
            Value::Null,
            &[("cookie", &cookie)]
        )
        .await
        .0,
        400
    );
    let ready = call(
        &f.app,
        "POST",
        "/api/auth/battlenet/poll",
        json!({"pollToken":poll}),
        &[],
    )
    .await;
    assert_eq!(ready.0, 200);
    assert!(
        ready.2["sessionToken"]
            .as_str()
            .unwrap()
            .starts_with("bne_")
    );
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/auth/battlenet/poll",
            json!({"pollToken":poll}),
            &[]
        )
        .await
        .0,
        401
    );
    assert_eq!(f.requests.load(Ordering::Relaxed), 1);
    let (poll, state, cookie) = f.begin().await;
    db::connect(&f.database())
        .unwrap()
        .execute("UPDATE battlenet_pairings SET expires_at=0", [])
        .unwrap();
    assert_eq!(
        call(
            &f.app,
            "GET",
            &format!("/api/auth/battlenet/callback?state={state}&code=approved"),
            Value::Null,
            &[("cookie", &cookie)]
        )
        .await
        .0,
        400
    );
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/auth/battlenet/poll",
            json!({"pollToken":poll}),
            &[]
        )
        .await
        .0,
        401
    );
    assert_eq!(f.requests.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn denial_provider_failures_pending_polling_and_start_limits_are_safe() {
    let f = Fixture::new().await;
    for query in ["error=access_denied", "code=provider-failure"] {
        let (poll, state, cookie) = f.begin().await;
        let failed = call(
            &f.app,
            "GET",
            &format!("/api/auth/battlenet/callback?state={state}&{query}"),
            Value::Null,
            &[("cookie", &cookie)],
        )
        .await;
        assert!(matches!(failed.0, 401 | 502));
        assert!(!failed.2.to_string().contains("private-provider-detail"));
        assert_eq!(failed.1["cache-control"], "no-store");
        assert_eq!(
            call(
                &f.app,
                "POST",
                "/api/auth/battlenet/poll",
                json!({"pollToken":poll}),
                &[]
            )
            .await
            .0,
            401
        );
    }
    let (poll, _, _) = f.begin().await;
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/auth/battlenet/poll",
            json!({"pollToken":poll}),
            &[]
        )
        .await
        .0,
        202
    );
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/auth/battlenet/poll",
            json!({"pollToken":poll}),
            &[]
        )
        .await
        .0,
        429
    );
    for _ in 0..17 {
        assert_eq!(
            call(&f.app, "POST", "/api/auth/battlenet/start", json!({}), &[])
                .await
                .0,
            200
        );
    }
    assert_eq!(
        call(&f.app, "POST", "/api/auth/battlenet/start", json!({}), &[])
            .await
            .0,
        429
    );
}

#[tokio::test]
async fn enrollment_binds_verified_players_revokes_legacy_credentials_and_blocks_every_fingerprint()
{
    let f = Fixture::new().await;
    let mut legacy = f.config.clone();
    legacy.battlenet = None;
    let legacy = router(legacy).unwrap();
    let old = call(
        &legacy,
        "POST",
        "/api/installations",
        registration("a"),
        &[],
    )
    .await;
    let old = format!("Bearer {}", old.2["token"].as_str().unwrap());
    let before = call(
        &f.app,
        "POST",
        "/api/scans",
        json!({}),
        &[("authorization", &old)],
    )
    .await;
    assert_eq!(before.0, 401);
    assert_eq!(before.2, json!({"error":"Battle.net sign-in required"}));
    assert_eq!(
        call(&f.app, "POST", "/api/installations", registration("a"), &[])
            .await
            .0,
        401
    );
    let session = f.session("approved").await;
    let auth = format!("Bearer {session}");
    let mut uploads = Vec::new();
    for digit in ["a", "b"] {
        let registered = call(
            &f.app,
            "POST",
            "/api/installations",
            registration(digit),
            &[("authorization", &auth)],
        )
        .await;
        assert_eq!(registered.0, 200);
        uploads.push(format!(
            "Bearer {}",
            registered.2["token"].as_str().unwrap()
        ));
    }
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/scans",
            json!({}),
            &[("authorization", &old)]
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/scans",
            json!({}),
            &[("authorization", &uploads[0])]
        )
        .await
        .0,
        400
    );
    // Enrollment credentials grant no upload or web-character access.
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/scans",
            json!({}),
            &[("authorization", &auth)]
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &f.app,
            "GET",
            "/api/account",
            Value::Null,
            &[("authorization", &auth)]
        )
        .await
        .0,
        401
    );
    let other = format!("Bearer {}", f.session("other-player").await);
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/installations",
            registration("a"),
            &[("authorization", &other)]
        )
        .await
        .0,
        409
    );
    let db = db::connect(&f.database()).unwrap();
    use sha2::{Digest, Sha256};
    let identity = hex::encode(Sha256::digest(b"battlenet:123"));
    let stored: String = db
        .query_row(
            "SELECT token_hash FROM battlenet_sessions WHERE identity_hash=?1",
            [&identity],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(stored, hex::encode(Sha256::digest(session.as_bytes())));
    db.execute(
        "UPDATE battlenet_identities SET blocked_at=unixepoch() WHERE identity_hash=?1",
        [&identity],
    )
    .unwrap();
    for upload in &uploads {
        let denied = call(
            &f.app,
            "POST",
            "/api/scans",
            json!({}),
            &[("authorization", upload)],
        )
        .await;
        assert_eq!(denied.0, 403);
        assert_eq!(denied.2, json!({"error":"this player is blocked"}));
    }
    let (blocked_poll, blocked_state, blocked_cookie) = f.begin().await;
    assert_eq!(
        call(
            &f.app,
            "GET",
            &format!("/api/auth/battlenet/callback?state={blocked_state}&code=approved"),
            Value::Null,
            &[("cookie", &blocked_cookie)]
        )
        .await
        .0,
        403
    );
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/auth/battlenet/poll",
            json!({"pollToken":blocked_poll}),
            &[]
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/installations",
            registration("c"),
            &[("authorization", &auth)]
        )
        .await
        .0,
        403
    );
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/installations",
            registration("c"),
            &[("authorization", &other)]
        )
        .await
        .0,
        200
    );
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/scans",
            json!({}),
            &[("authorization", "Bearer admin-token")]
        )
        .await
        .0,
        400
    );
    db.execute(
        "UPDATE battlenet_identities SET blocked_at=NULL WHERE identity_hash=?1",
        [&identity],
    )
    .unwrap();
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/scans",
            json!({}),
            &[("authorization", &uploads[0])]
        )
        .await
        .0,
        400
    );
    db.execute("UPDATE battlenet_sessions SET expires_at=0", [])
        .unwrap();
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/installations",
            registration("d"),
            &[("authorization", &auth)]
        )
        .await
        .0,
        401
    );
}
