use axum::{
    Router,
    body::{Body, to_bytes},
    extract::ConnectInfo,
    http::{HeaderMap, Request},
};
use goldbook_server::{AuctionConfig, BattleNetConfig, Config, Poller, db, router};
use serde_json::{Value, json};
use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};
use tower::ServiceExt;

struct Fixture {
    directory: PathBuf,
    app: Router,
    // "Bearer <token>" of two players' installs, registered after Battle.net sign-in.
    player: String,
    friend: String,
    // "Bearer <session>" of the first player's Battle.net sign-in.
    session: String,
}
impl Fixture {
    async fn new() -> Self {
        Self::build(|_| {}).await
    }
    // A server over a database that `seed` prepared before the server's first
    // start, as a deployment's database was before this server version.
    async fn build(seed: impl FnOnce(&Path)) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let directory = std::env::temp_dir().join(format!(
            "goldbook-server-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let database = directory.join("goldbook.sqlite");
        seed(&database);
        let app = router(battlenet(database.clone())).unwrap();
        let player = register(&app, &database, "player").await;
        let friend = register(&app, &database, "friend").await;
        Self {
            directory,
            app,
            player,
            friend,
            session: format!("Bearer {}", sign_in(&database, "player")),
        }
    }
    fn database(&self) -> PathBuf {
        self.directory.join("goldbook.sqlite")
    }
    fn auth(&self) -> [(&'static str, &str); 1] {
        [("authorization", &self.player)]
    }
    fn friend_auth(&self) -> [(&'static str, &str); 1] {
        [("authorization", &self.friend)]
    }
    fn session(&self) -> [(&'static str, &str); 1] {
        [("authorization", &self.session)]
    }
}
// A server that signs in with Battle.net. Sign-in never runs in these tests,
// so the provider is never called; tests/oauth.rs covers it.
fn battlenet(database: PathBuf) -> Config {
    let mut config = Config::new(database);
    config.battlenet = Some(BattleNetConfig::new(
        "client".into(),
        "test-secret".into(),
        "https://gold.example/goldbook".into(),
    ));
    config
}
// The Battle.net session `player` holds after sign-in, written straight into the database.
fn sign_in(database: &std::path::Path, player: &str) -> String {
    use sha2::{Digest, Sha256};
    let identity = hex::encode(Sha256::digest(format!("battlenet:{player}")));
    let session = format!("session-{player}");
    let db = db::connect(database).unwrap();
    db.execute(
        "INSERT OR IGNORE INTO battlenet_identities (identity_hash) VALUES (?1)",
        [&identity],
    )
    .unwrap();
    db.execute(
        "INSERT OR REPLACE INTO battlenet_sessions (token_hash,identity_hash,expires_at) VALUES (?1,?2,unixepoch()+3600)",
        [hex::encode(Sha256::digest(&session)), identity],
    )
    .unwrap();
    session
}
// An upload token for `player`, as the app registers one after Battle.net sign-in.
async fn register(app: &Router, database: &std::path::Path, player: &str) -> String {
    use sha2::{Digest, Sha256};
    let session = sign_in(database, player);
    let fingerprint = hex::encode(Sha256::digest(format!("account:{player}")));
    let (status, _, body) = call(
        app,
        "POST",
        "/api/installations",
        json!({"fingerprint":fingerprint,"fingerprintVersion":1}),
        &[("authorization", &format!("Bearer {session}"))],
    )
    .await;
    assert_eq!(status, 200, "{body}");
    format!("Bearer {}", body["token"].as_str().unwrap())
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}
// A database as the server left it before migration `next`: the migrations
// before it applied and recorded, as verify-migration.py's exercise_upgrade
// builds one.
fn migrated_until(database: &Path, next: &str) -> rusqlite::Connection {
    let db = db::connect(database).unwrap();
    db.execute_batch(
        "CREATE TABLE migrations (name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)",
    )
    .unwrap();
    let mut files: Vec<_> = std::fs::read_dir(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../server/migrations"
    ))
    .unwrap()
    .map(|entry| entry.unwrap().path())
    .collect();
    files.sort();
    for path in files {
        let name = path.file_name().unwrap().to_str().unwrap();
        if name >= next {
            break;
        }
        db.execute_batch(&std::fs::read_to_string(&path).unwrap())
            .unwrap();
        db.execute("INSERT INTO migrations VALUES (?1, 0)", [name])
            .unwrap();
    }
    db
}
async fn raw(
    app: &Router,
    method: &str,
    target: &str,
    body: Vec<u8>,
    headers: &[(&str, &str)],
) -> (u16, HeaderMap, Vec<u8>) {
    let mut request = Request::builder()
        .method(method)
        .uri(target)
        .header("content-length", body.len());
    for (key, value) in headers {
        request = request.header(*key, *value);
    }
    let mut request = request.body(Body::from(body)).unwrap();
    request.extensions_mut().insert(ConnectInfo(
        "203.0.113.7:2222".parse::<SocketAddr>().unwrap(),
    ));
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    assert_eq!(headers["x-content-type-options"], "nosniff");
    assert_eq!(headers["referrer-policy"], "same-origin");
    assert!(headers.contains_key("content-security-policy"));
    (
        status,
        headers,
        to_bytes(response.into_body(), 30 * 1024 * 1024)
            .await
            .unwrap()
            .to_vec(),
    )
}
async fn call(
    app: &Router,
    method: &str,
    target: &str,
    body: Value,
    headers: &[(&str, &str)],
) -> (u16, HeaderMap, Value) {
    let payload = if method == "GET" {
        vec![]
    } else {
        serde_json::to_vec(&body).unwrap()
    };
    let mut headers = headers.to_vec();
    if method == "POST" {
        headers.push(("content-type", "application/json"));
    }
    let (status, headers, body) = raw(app, method, target, payload, &headers).await;
    (status, headers, serde_json::from_slice(&body).unwrap())
}
fn scan() -> Value {
    json!({"realm":"Faramon","faction":"Horde","region":"EU","scannedAt":1760000000,"mode":"replicate","scanner":"Sultan","build":"1.60.1.70338","rows":[["2589",110,125,42,3],["7070",300,320,5,2]],"items":{"2589":["Linen Cloth",1],"7070":["Elemental Water",1]}})
}
fn account() -> Value {
    json!({"id":"K7Q2M9PX","keyHash":goldbook_core::key_hash("7KQ2M9PXABCDEFGHJKMN"),"characters":[{"name":"Sultan","realm":"Faramon","faction":"Horde","class":"MAGE","level":60,"updatedAt":1791970261_u64,"gold":[[1791932400_u64,1],[1791846000_u64,50],[1791932400_u64,2]],"bags":{"at":null,"rows":[]},"bank":null}]})
}
#[tokio::test]
async fn scans_preserve_identity_late_names_market_borrowing_and_queries() {
    let f = Fixture::new().await;
    let mut first = scan();
    first["items"] = json!({});
    assert_eq!(
        call(&f.app, "POST", "/api/scans", first, &f.auth()).await.2,
        json!({"stored":true,"items":2})
    );
    let mut retry = scan();
    retry["rows"].as_array_mut().unwrap().reverse();
    assert_eq!(
        call(&f.app, "POST", "/api/scans", retry, &f.auth()).await.2,
        json!({"stored":false,"items":2})
    );
    let mut quick = scan();
    quick["mode"] = json!("browse");
    quick["rows"] = json!([["2589", 100, 0, 10, 0]]);
    assert_eq!(
        call(&f.app, "POST", "/api/scans", quick, &f.friend_auth())
            .await
            .0,
        200
    );
    let (_, _, prices) = call(
        &f.app,
        "GET",
        "/api/prices?realm=Faramon&faction=Horde&sort=market",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(prices["scan"]["id"], 2);
    assert_eq!(prices["marketScan"]["id"], 1);
    assert_eq!(prices["items"][0]["minBuyout"], 100);
    assert_eq!(prices["items"][0]["marketValue"], 125);
    let (_, _, search) = call(
        &f.app,
        "GET",
        "/api/prices?realm=Faramon&faction=Horde&q=cloth&offset=50",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(search["total"], 1);
    assert_eq!(search["items"], json!([]));
    let (_, _, history) = call(
        &f.app,
        "GET",
        "/api/history?realm=Faramon&faction=Horde&itemKey=2589",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(history["name"], "Linen Cloth");
    assert_eq!(history["points"].as_array().unwrap().len(), 2);
    let (_, _, trends) = call(
        &f.app,
        "GET",
        "/api/trends?realm=Faramon&faction=Horde&items=2589,2589",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(trends["days"].as_array().unwrap().len(), 14);
    assert_eq!(trends["items"]["2589"][13], 100);
}
#[tokio::test]
async fn export_folds_a_realms_scans_into_prices_hours_and_days() {
    let f = Fixture::new().await;
    let scans = [
        (
            "Faramon",
            "Horde",
            1754870399,
            "replicate",
            json!([["2589", 50, 60, 9, 1], ["999", 10, 10, 1, 1]]),
            json!({"999": ["Old Item", 2]}),
        ),
        (
            "Faramon",
            "Horde",
            1754870400,
            "browse",
            json!([["2589", 120, 0, 30, 0], ["7070", 300, 0, 5, 0]]),
            json!({"7070": ["Elemental Water", 1]}),
        ),
        (
            "Faramon",
            "Horde",
            1759485600,
            "replicate",
            json!([["2589", 115, 118, 20, 2]]),
            json!({}),
        ),
        (
            "Faramon",
            "Horde",
            1760083260,
            "replicate",
            json!([
                ["2589", 110, 125, 42, 3],
                ["2592", 200, 210, 4, 1],
                ["4306:1024", 500, 520, 3, 1]
            ]),
            json!({"2589": ["Linen Cloth", 1]}),
        ),
        (
            "Faramon",
            "Horde",
            1760086900,
            "browse",
            json!([
                ["2589", 100, 0, 10, 0],
                ["2592", 190, 0, 3, 0],
                ["4306:1024", 480, 0, 2, 0]
            ]),
            json!({"2592": ["Wool Cloth", 1]}),
        ),
        (
            "Faramon",
            "Horde",
            1760090000,
            "replicate",
            json!([["2589", 100, 105, 100, 4], ["4306:1024", 470, 490, 6, 2]]),
            json!({}),
        ),
        (
            "Faramon",
            "Horde",
            1760090000,
            "replicate",
            json!([["2589", 100, 107, 7, 5], ["4306:1024", 470, 495, 8, 3]]),
            json!({}),
        ),
        (
            "Faramon",
            "Alliance",
            1760095000,
            "replicate",
            json!([["2589", 1, 1, 1, 1]]),
            json!({}),
        ),
        (
            "Gehennas",
            "Horde",
            1760099000,
            "replicate",
            json!([["2589", 1, 1, 1, 1], ["8000", 1, 1, 1, 1]]),
            json!({}),
        ),
    ];
    for (realm, faction, at, mode, rows, items) in scans {
        let scan = json!({"realm":realm,"faction":faction,"region":"EU","scannedAt":at,"mode":mode,"scanner":"Sultan","build":"1.60.1.70338","rows":rows,"items":items});
        assert_eq!(
            call(&f.app, "POST", "/api/scans", scan, &f.auth()).await.0,
            200
        );
    }
    let (status, _, export) = call(
        &f.app,
        "GET",
        "/api/export?realm=Faramon&faction=Horde",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(
        export,
        json!({
            "realm": "Faramon",
            "faction": "Horde",
            "scannedAt": 1760090000,
            "items": {
                "2589": {
                    "name": "Linen Cloth",
                    "quality": 1,
                    "price": [100, 7, 5, 1760090000, 107, 1760090000],
                    "hours": [[488746, 115, 20, 118], [488912, 110, 42, 125], [488913, 100, 10, 107]],
                    "days": [[20311, 120, 30, 0], [20364, 115, 20, 118], [20371, 100, 10, 107]]
                },
                "2592": {
                    "name": "Wool Cloth",
                    "quality": 1,
                    "price": [190, 3, 0, 1760086900, 210, 1760083260],
                    "hours": [[488912, 200, 4, 210], [488913, 190, 3, 0]],
                    "days": [[20371, 190, 3, 210]]
                },
                "4306:1024": {
                    "name": null,
                    "quality": null,
                    "price": [470, 8, 3, 1760090000, 495, 1760090000],
                    "hours": [[488912, 500, 3, 520], [488913, 470, 6, 495]],
                    "days": [[20371, 470, 6, 495]]
                },
                "7070": {
                    "name": "Elemental Water",
                    "quality": 1,
                    "price": [300, 5, 0, 1754870400, 0, 0],
                    "hours": [],
                    "days": [[20311, 300, 5, 0]]
                }
            }
        })
    );
    let target = "/api/export?realm=Faramon&faction=Horde";
    let (_, headers, gzipped) = raw(
        &f.app,
        "GET",
        target,
        vec![],
        &[("accept-encoding", "br, GZIP;q=0.5")],
    )
    .await;
    assert_eq!(
        (&headers["content-encoding"], &headers["vary"]),
        (
            &"gzip".parse().unwrap(),
            &"accept-encoding".parse().unwrap()
        )
    );
    assert_eq!(
        headers["content-length"],
        gzipped.len().to_string().as_str()
    );
    let mut unzipped = String::new();
    std::io::Read::read_to_string(
        &mut flate2::read::GzDecoder::new(&gzipped[..]),
        &mut unzipped,
    )
    .unwrap();
    assert_eq!(serde_json::from_str::<Value>(&unzipped).unwrap(), export);
    for refused in ["gzip;q=0", "deflate", ""] {
        let (_, headers, plain) = raw(
            &f.app,
            "GET",
            target,
            vec![],
            &[("accept-encoding", refused)],
        )
        .await;
        assert!(!headers.contains_key("content-encoding"), "{refused}");
        assert_eq!(
            serde_json::from_slice::<Value>(&plain).unwrap(),
            export,
            "{refused}"
        );
    }
    for (target, expected) in [
        (
            "/api/export?realm=Faramon",
            (400, json!({"error": "faction is required"})),
        ),
        (
            "/api/export?realm=Nowhere&faction=Horde",
            (404, json!({"error": "no scans for this realm and faction"})),
        ),
    ] {
        let (status, _, body) = call(&f.app, "GET", target, Value::Null, &[]).await;
        assert_eq!((status, body), expected, "{target}");
    }
}
// Faramon-Horde's scans on the three days before day 20371 and on that day,
// one the day before the export's window, and one of the Alliance.
async fn market() -> Fixture {
    let f = Fixture::new().await;
    let names = json!({
        "2589": ["Linen Cloth", 1], "2592": ["Wool Cloth", 1], "2318": ["Light Leather", 1],
        "2319": ["Medium Leather", 1], "4306": ["Silk Cloth", 1], "2320": ["Coarse Thread", 1],
        "2835": ["Rough Stone", 1], "7070": ["Elemental Water", 1], "2449": ["Earthroot", 1],
        "765": ["Silverleaf", 1]
    });
    let scans = [
        (
            "Horde",
            1754870399,
            "replicate",
            json!([["2319", 10000, 10000, 3, 1]]),
        ),
        (
            "Horde",
            1759798800,
            "replicate",
            json!([
                ["2589", 10000, 10500, 5, 2],
                ["2318", 10000, 10000, 3, 1],
                ["4306", 10000, 10000, 3, 1],
                ["2320", 10000, 10000, 3, 1],
                ["2770", 1000, 1000, 3, 1]
            ]),
        ),
        (
            "Horde",
            1759885200,
            "replicate",
            json!([
                ["2589", 11000, 11000, 5, 2],
                ["2318", 10000, 10000, 3, 1],
                ["2319", 10000, 10000, 3, 1],
                ["4306", 10000, 10000, 3, 1],
                ["2320", 10000, 10000, 3, 1],
                ["2770", 1000, 1000, 3, 1]
            ]),
        ),
        (
            "Horde",
            1759971600,
            "browse",
            json!([
                ["2589", 9000, 0, 5, 0],
                ["2318", 10000, 0, 3, 0],
                ["2319", 10000, 0, 3, 0],
                ["4306", 1000, 0, 3, 0],
                ["2320", 10000, 0, 3, 0],
                ["2770", 1000, 0, 3, 0],
                ["2835", 50, 0, 3, 0],
                ["7070", 300, 0, 3, 0],
                ["2449", 1000, 0, 3, 0],
                ["765", 200, 0, 3, 0]
            ]),
        ),
        (
            "Horde",
            1759975200,
            "browse",
            json!([["2589", 9500, 0, 5, 0]]),
        ),
        (
            "Horde",
            1760058000,
            "replicate",
            json!([
                ["2589", 6000, 30000, 4, 2],
                ["2592", 5000, 10000, 12, 3],
                ["2318", 7500, 12000, 3, 1],
                ["2319", 5000, 0, 2, 1],
                ["2320", 1000, 0, 20, 2],
                ["2770", 500, 0, 7, 2],
                ["2835", 90, 95, 40, 4],
                ["7070", 450, 0, 5, 1],
                ["2449", 1100, 1200, 9, 2],
                ["765", 200, 210, 6, 1]
            ]),
        ),
        (
            "Alliance",
            1759971660,
            "browse",
            json!([["2589", 1, 0, 1, 0]]),
        ),
    ];
    for (faction, at, mode, rows) in scans {
        let scan = json!({"realm":"Faramon","faction":faction,"region":"EU","scannedAt":at,"mode":mode,"scanner":"Sultan","build":"1.60.1.70338","rows":rows,"items":names});
        assert_eq!(
            call(&f.app, "POST", "/api/scans", scan, &f.auth()).await.0,
            200
        );
    }
    f
}
fn newest() -> Value {
    json!({"id":6,"scannedAt":1760058000,"mode":"replicate","itemCount":10,"scanner":"Sultan"})
}
#[tokio::test]
async fn deals_are_the_flips_the_addon_finds_in_the_newest_scan() {
    let f = market().await;
    let wool = json!({"itemKey":"2592","name":"Wool Cloth","quality":1,"minBuyout":5000,"sell":10000,"profit":4500,"quantity":12});
    let linen = json!({"itemKey":"2589","name":"Linen Cloth","quality":1,"minBuyout":6000,"sell":10000,"profit":3500,"quantity":4});
    let unnamed = json!({"itemKey":"2770","name":null,"quality":null,"minBuyout":500,"sell":1000,"profit":450,"quantity":7});
    for (query, expected) in [
        (
            "",
            json!({"scan":newest(),"minProfit":1000,"total":2,"items":[wool, linen]}),
        ),
        (
            "&minProfit=400",
            json!({"scan":newest(),"minProfit":400,"total":3,"items":[wool, linen, unnamed]}),
        ),
        (
            "&minProfit=400&limit=1&offset=1",
            json!({"scan":newest(),"minProfit":400,"total":3,"items":[linen]}),
        ),
        (
            "&q=linen",
            json!({"scan":newest(),"minProfit":1000,"total":1,"items":[linen]}),
        ),
    ] {
        let target = format!("/api/deals?realm=Faramon&faction=Horde{query}");
        let (status, _, body) = call(&f.app, "GET", &target, Value::Null, &[]).await;
        assert_eq!((status, body), (200, expected), "{query}");
    }
    for (target, expected) in [
        (
            "/api/deals?realm=Faramon&faction=Horde&minProfit=-1",
            (
                400,
                json!({"error":"minProfit must be an integer from 0 to 9007199254740991"}),
            ),
        ),
        (
            "/api/deals?realm=Faramon&faction=Horde&quality=9",
            (
                400,
                json!({"error":"quality must be an integer from 0 to 7"}),
            ),
        ),
        (
            "/api/deals?realm=Faramon",
            (400, json!({"error":"faction is required"})),
        ),
        (
            "/api/deals?realm=Nowhere&faction=Horde",
            (404, json!({"error":"no scans for this realm and faction"})),
        ),
    ] {
        let (status, _, body) = call(&f.app, "GET", target, Value::Null, &[]).await;
        assert_eq!((status, body), expected, "{target}");
    }
}
#[tokio::test]
async fn movers_compare_the_newest_scan_with_the_day_before() {
    let f = market().await;
    let item = |key: &str, name: &str, min: u64, before: u64, change: f64, quantity: u64| json!({"itemKey":key,"name":name,"quality":1,"minBuyout":min,"before":before,"change":change,"quantity":quantity});
    let unnamed = json!({"itemKey":"2770","name":null,"quality":null,"minBuyout":500,"before":1000,"change":-50.0,"quantity":7});
    for (query, expected) in [
        (
            "",
            json!({"scan":newest(),"total":2,"items":[
                item("7070", "Elemental Water", 450, 300, 50.0, 5),
                item("2449", "Earthroot", 1100, 1000, 10.0, 9),
            ]}),
        ),
        (
            "&direction=fallers",
            json!({"scan":newest(),"total":5,"items":[
                item("2320", "Coarse Thread", 1000, 10000, -90.0, 20),
                item("2319", "Medium Leather", 5000, 10000, -50.0, 2),
                unnamed,
                item("2589", "Linen Cloth", 6000, 9000, -33.3, 4),
                item("2318", "Light Leather", 7500, 10000, -25.0, 3),
            ]}),
        ),
        (
            "&direction=fallers&q=leather&limit=1",
            json!({"scan":newest(),"total":2,"items":[
                item("2319", "Medium Leather", 5000, 10000, -50.0, 2),
            ]}),
        ),
    ] {
        let target = format!("/api/movers?realm=Faramon&faction=Horde{query}");
        let (status, _, body) = call(&f.app, "GET", &target, Value::Null, &[]).await;
        assert_eq!((status, body), (200, expected), "{query}");
    }
    for (target, expected) in [
        (
            "/api/movers?realm=Faramon&faction=Horde&direction=up",
            (
                400,
                json!({"error":"direction must be one of risers, fallers"}),
            ),
        ),
        (
            "/api/movers?realm=Nowhere&faction=Horde",
            (404, json!({"error":"no scans for this realm and faction"})),
        ),
    ] {
        let (status, _, body) = call(&f.app, "GET", target, Value::Null, &[]).await;
        assert_eq!((status, body), expected, "{target}");
    }
}
#[tokio::test]
async fn account_ownership_rotation_and_sessions_remain_atomic() {
    let f = Fixture::new().await;
    assert_eq!(
        call(&f.app, "POST", "/api/account", account(), &f.auth())
            .await
            .0,
        200
    );
    let (status, headers, _) = call(
        &f.app,
        "POST",
        "/api/login",
        json!({"id":"k7q2-m9px","key":"7kq2m-9pxab-cdefg-hjkmn"}),
        &[("x-forwarded-proto", "https, http")],
    )
    .await;
    assert_eq!(status, 200);
    let cookie = headers["set-cookie"].to_str().unwrap();
    assert!(cookie.ends_with("; Secure"));
    assert!(cookie.contains("HttpOnly; SameSite=Strict"));
    let cookie = cookie.split(';').next().unwrap();
    let (_, _, list) = call(
        &f.app,
        "GET",
        "/api/account",
        Value::Null,
        &[("cookie", cookie)],
    )
    .await;
    assert_eq!(list["characters"][0]["gold"], 2);
    let (_, _, detail) = call(
        &f.app,
        "GET",
        "/api/character?name=Sultan&realm=Faramon",
        Value::Null,
        &[("cookie", cookie)],
    )
    .await;
    assert_eq!(
        detail["gold"],
        json!([[1791846000_u64, 50], [1791932400_u64, 2]])
    );
    assert_eq!(detail["bags"], json!({"at":null,"rows":[],"total":0}));
    let mut rotated = account();
    let old = rotated["keyHash"].clone();
    rotated["keyHash"] = json!(goldbook_core::key_hash("ABCDEFGHJKMNPQRSTVWX"));
    assert_eq!(
        call(&f.app, "POST", "/api/account", rotated.clone(), &f.auth())
            .await
            .0,
        409
    );
    assert_eq!(
        call(
            &f.app,
            "GET",
            "/api/account",
            Value::Null,
            &[("cookie", cookie)]
        )
        .await
        .0,
        200
    );
    rotated["previousKeyHash"] = old;
    assert_eq!(
        call(&f.app, "POST", "/api/account", rotated, &f.auth())
            .await
            .0,
        200
    );
    assert_eq!(
        call(
            &f.app,
            "GET",
            "/api/account",
            Value::Null,
            &[("cookie", cookie)]
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/login",
            json!({"id":"K7Q2M9PX","key":"7KQ2M9PXABCDEFGHJKMN"}),
            &[]
        )
        .await
        .0,
        401
    );
}
fn trade(name: &str, at: u64, side: &str, item: &str, key: Value, price: u64, fee: u64) -> Value {
    json!({"name":name,"realm":"Faramon","at":at,"side":side,"item":item,"itemKey":key,"count":20,"price":price,"fee":fee})
}
async fn log_in(app: &Router, id: &str, key: &str) -> String {
    let (_, headers, _) = call(app, "POST", "/api/login", json!({"id":id,"key":key}), &[]).await;
    headers["set-cookie"]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned()
}
#[tokio::test]
async fn trades_accumulate_once_each_and_stay_with_their_account() {
    let f = Fixture::new().await;
    call(&f.app, "POST", "/api/scans", scan(), &f.auth()).await;
    let sale = trade(
        "Sultan",
        1760000100,
        "sell",
        "Linen Cloth",
        json!("2589"),
        2000,
        100,
    );
    let mut upload = account();
    upload["trades"] = json!([
        sale,
        sale,
        trade(
            "Sultan",
            1760000000,
            "buy",
            "Bandit Cinch of the Monkey",
            json!(null),
            9000,
            0
        ),
        trade(
            "Mirelle",
            1760000200,
            "buy",
            "Linen Cloth",
            json!("2589"),
            1500,
            0
        ),
    ]);
    assert_eq!(
        call(&f.app, "POST", "/api/account", upload.clone(), &f.auth())
            .await
            .2,
        json!({"stored":true,"characters":1})
    );
    let cookie = log_in(&f.app, "K7Q2M9PX", "7KQ2M9PXABCDEFGHJKMN").await;
    let all = || async {
        call(
            &f.app,
            "GET",
            "/api/trades",
            Value::Null,
            &[("cookie", cookie.as_str())],
        )
        .await
        .2["trades"]
            .clone()
    };
    let first = all().await;
    assert_eq!(
        first.as_array().unwrap().len(),
        4,
        "two equal sales stay two trades"
    );
    assert_eq!(
        first[0],
        json!({"name":"Mirelle","realm":"Faramon","at":1760000200,"side":"buy","item":"Linen Cloth","itemKey":"2589","quality":1,"count":20,"price":1500,"fee":0,"party":null}),
        "newest first, with the quality of a known item"
    );
    assert_eq!(first[3]["quality"], Value::Null);
    call(&f.app, "POST", "/api/account", upload.clone(), &f.auth()).await;
    upload["trades"] = json!([
        sale,
        trade(
            "Sultan",
            1760000000,
            "buy",
            "Bandit Cinch of the Monkey",
            json!("9775:584"),
            9000,
            0
        ),
    ]);
    call(&f.app, "POST", "/api/account", upload.clone(), &f.auth()).await;
    let after = all().await;
    assert_eq!(
        after.as_array().unwrap().len(),
        4,
        "a repeated upload adds nothing, and trades the addon dropped stay"
    );
    assert_eq!(
        after[3]["itemKey"], "9775:584",
        "a key learnt later fills in"
    );
    let (_, _, sultan) = call(
        &f.app,
        "GET",
        "/api/trades?name=Sultan&realm=Faramon",
        Value::Null,
        &[("cookie", cookie.as_str())],
    )
    .await;
    assert_eq!(sultan["trades"].as_array().unwrap().len(), 3);
    assert_eq!(
        call(
            &f.app,
            "GET",
            "/api/trades?name=Sultan",
            Value::Null,
            &[("cookie", cookie.as_str())]
        )
        .await
        .0,
        400
    );
    assert_eq!(
        call(&f.app, "GET", "/api/trades", Value::Null, &[]).await.0,
        401
    );
    upload["trades"] = json!([trade(
        "Sultan",
        1760000000,
        "sell",
        "Linen Cloth",
        json!(null),
        100,
        101
    )]);
    let (status, _, error) = call(&f.app, "POST", "/api/account", upload, &f.auth()).await;
    assert_eq!(
        (status, error["error"].clone()),
        (
            400,
            json!("trades[0].fee must not exceed the price, and only an auction sale has one")
        )
    );
    let mut other = account();
    other["id"] = json!("ABCDEFGH");
    other["keyHash"] = json!(goldbook_core::key_hash("ABCDEFGHJKMNPQRSTVWX"));
    call(&f.app, "POST", "/api/account", other, &f.auth()).await;
    let stranger = log_in(&f.app, "ABCDEFGH", "ABCDEFGHJKMNPQRSTVWX").await;
    let (_, _, theirs) = call(
        &f.app,
        "GET",
        "/api/trades",
        Value::Null,
        &[("cookie", stranger.as_str())],
    )
    .await;
    assert_eq!(
        theirs["trades"],
        json!([]),
        "another account sees none of them"
    );
}
#[tokio::test]
async fn vendor_sales_are_trades_without_a_cut() {
    let f = Fixture::new().await;
    let mut upload = account();
    upload["trades"] = json!([
        trade(
            "Sultan",
            1760000000,
            "buy",
            "Jagged Star of the Eagle",
            json!("15301:1019"),
            2300,
            0
        ),
        trade(
            "Sultan",
            1760000600,
            "vendor",
            "Jagged Star of the Eagle",
            json!("15301:1019"),
            3100,
            0
        ),
    ]);
    assert_eq!(
        call(&f.app, "POST", "/api/account", upload.clone(), &f.auth())
            .await
            .0,
        200
    );
    let cookie = log_in(&f.app, "K7Q2M9PX", "7KQ2M9PXABCDEFGHJKMN").await;
    let (_, _, listed) = call(
        &f.app,
        "GET",
        "/api/trades",
        Value::Null,
        &[("cookie", cookie.as_str())],
    )
    .await;
    assert_eq!(
        listed["trades"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| (t["side"].as_str().unwrap(), t["price"].as_u64().unwrap()))
            .collect::<Vec<_>>(),
        [("vendor", 3100), ("buy", 2300)]
    );
    upload["trades"] = json!([trade(
        "Sultan",
        1760000700,
        "vendor",
        "Broken Fang",
        json!(null),
        85,
        4
    )]);
    let (status, _, error) = call(&f.app, "POST", "/api/account", upload, &f.auth()).await;
    assert_eq!(
        (status, error["error"].clone()),
        (
            400,
            json!("trades[0].fee must not exceed the price, and only an auction sale has one")
        )
    );
}
fn entry(at: u64, side: &str, item: &str, count: u64, price: u64, party: Option<&str>) -> Value {
    json!({"name":"Sultan","realm":"Faramon","at":at,"side":side,"item":item,"itemKey":null,"count":count,"price":price,"fee":0,"party":party})
}
#[tokio::test]
async fn accounting_books_goods_and_gold_alone_with_the_other_player() {
    let f = Fixture::new().await;
    let mut upload = account();
    let mut sale = entry(
        1760000900,
        "tradeSell",
        "Linen Cloth",
        20,
        0,
        Some("Mirelle"),
    );
    sale["itemKey"] = json!("2589");
    let entries = [
        sale,
        entry(1760000850, "tradeIn", "Gold", 1, 50000, Some("Mirelle")),
        entry(
            1760000800,
            "cod",
            "Gnomish Widget",
            1,
            7000,
            Some("Mirelle"),
        ),
        entry(1760000700, "merchant", "Simple Flour", 5, 125, None),
        entry(
            1760000600,
            "mailIn",
            "Thanks for the help",
            1,
            12000,
            Some("Mirelle"),
        ),
        entry(1760000500, "quest", "The Defias Brotherhood", 1, 3500, None),
        entry(1760000400, "repair", "Repairs", 1, 3456, None),
        entry(1759996800, "loot", "Looted gold", 37, 8120, None),
    ];
    upload["trades"] = json!(entries);
    assert_eq!(
        call(&f.app, "POST", "/api/account", upload.clone(), &f.auth())
            .await
            .0,
        200
    );
    let cookie = log_in(&f.app, "K7Q2M9PX", "7KQ2M9PXABCDEFGHJKMN").await;
    let expected = json!([
        {"name":"Sultan","realm":"Faramon","at":1760000900,"side":"tradeSell","item":"Linen Cloth","itemKey":"2589","quality":null,"count":20,"price":0,"fee":0,"party":"Mirelle"},
        {"name":"Sultan","realm":"Faramon","at":1760000850,"side":"tradeIn","item":"Gold","itemKey":null,"quality":null,"count":1,"price":50000,"fee":0,"party":"Mirelle"},
        {"name":"Sultan","realm":"Faramon","at":1760000800,"side":"cod","item":"Gnomish Widget","itemKey":null,"quality":null,"count":1,"price":7000,"fee":0,"party":"Mirelle"},
        {"name":"Sultan","realm":"Faramon","at":1760000700,"side":"merchant","item":"Simple Flour","itemKey":null,"quality":null,"count":5,"price":125,"fee":0,"party":null},
        {"name":"Sultan","realm":"Faramon","at":1760000600,"side":"mailIn","item":"Thanks for the help","itemKey":null,"quality":null,"count":1,"price":12000,"fee":0,"party":"Mirelle"},
        {"name":"Sultan","realm":"Faramon","at":1760000500,"side":"quest","item":"The Defias Brotherhood","itemKey":null,"quality":null,"count":1,"price":3500,"fee":0,"party":null},
        {"name":"Sultan","realm":"Faramon","at":1760000400,"side":"repair","item":"Repairs","itemKey":null,"quality":null,"count":1,"price":3456,"fee":0,"party":null},
        {"name":"Sultan","realm":"Faramon","at":1759996800,"side":"loot","item":"Looted gold","itemKey":null,"quality":null,"count":37,"price":8120,"fee":0,"party":null}
    ]);
    assert_eq!(
        get(&f.app, "/api/trades", &cookie).await["trades"],
        expected
    );
    for t in upload["trades"].as_array_mut().unwrap() {
        t.as_object_mut().unwrap().remove("party");
    }
    call(&f.app, "POST", "/api/account", upload.clone(), &f.auth()).await;
    assert_eq!(
        get(&f.app, "/api/trades", &cookie).await["trades"],
        expected,
        "an upload without the party adds nothing and keeps the party booked before"
    );
    for (bad, message) in [
        (
            entry(1760001000, "gift", "Gold", 1, 100, Some("Mirelle")),
            "trades[0].side must be one of sell, buy, vendor, merchant, tradeSell, tradeBuy, tradeIn, tradeOut, mailIn, mailOut, cod, quest, loot, repair, postage, deposit, travel, training, respec, otherIn, otherOut",
        ),
        (
            entry(1760001000, "mailOut", "Gold", 1, 0, Some("Mirelle")),
            "trades[0].price must be a positive integer",
        ),
        (
            entry(1760001000, "mailOut", "Gold", 1, 100, Some("")),
            "trades[0].party must be a string of 1 to 64 characters",
        ),
    ] {
        upload["trades"] = json!([bad]);
        let (status, _, error) =
            call(&f.app, "POST", "/api/account", upload.clone(), &f.auth()).await;
        assert_eq!((status, error["error"].clone()), (400, json!(message)));
    }
    assert_eq!(
        get(&f.app, "/api/trades", &cookie).await["trades"],
        expected
    );
    let sides = "sell buy vendor merchant tradeSell tradeBuy tradeIn tradeOut mailIn mailOut cod \
        quest loot repair postage deposit travel training respec otherIn otherOut";
    upload["trades"] = sides
        .split_whitespace()
        .map(|side| entry(1760002000, side, "Gold", 1, 100, None))
        .collect();
    assert_eq!(
        call(&f.app, "POST", "/api/account", upload, &f.auth())
            .await
            .0,
        200
    );
    assert_eq!(
        get(&f.app, "/api/trades", &cookie).await["trades"]
            .as_array()
            .unwrap()
            .len(),
        8 + 21,
        "the table takes every side the upload does"
    );
}
async fn get(app: &Router, target: &str, cookie: &str) -> Value {
    let (status, _, body) = call(app, "GET", target, Value::Null, &[("cookie", cookie)]).await;
    assert_eq!(status, 200, "{target}: {body}");
    body
}
async fn link(app: &Router, cookie: Option<&str>, id: &str, key: &str) -> (u16, HeaderMap, Value) {
    let headers: Vec<_> = cookie.map(|c| ("cookie", c)).into_iter().collect();
    call(
        app,
        "POST",
        "/api/link",
        json!({"id":id,"key":key}),
        &headers,
    )
    .await
}
#[tokio::test]
async fn linked_ids_share_their_characters_and_trades() {
    let f = Fixture::new().await;
    let sale = trade(
        "Sultan",
        1760000100,
        "sell",
        "Linen Cloth",
        json!("2589"),
        2000,
        100,
    );
    let mut mac = account();
    mac["trades"] = json!([sale]);
    call(&f.app, "POST", "/api/account", mac, &f.auth()).await;
    let mut fedora = account();
    fedora["id"] = json!("ABCDEFGH");
    fedora["keyHash"] = json!(goldbook_core::key_hash("ABCDEFGHJKMNPQRSTVWX"));
    fedora["characters"] = json!([
        {"name":"Sultan","realm":"Faramon","faction":"Horde","class":"MAGE","level":61,"updatedAt":1791980000_u64,
         "gold":[[1791932400_u64,7],[1792018800_u64,90]],"bags":{"at":1791980000_u64,"rows":[]},"bank":null},
        {"name":"Mirelle","realm":"Faramon","faction":"Horde","class":"PRIEST","level":20,"updatedAt":1791900000_u64,
         "gold":[[1791932400_u64,5]],"bags":null,"bank":null}
    ]);
    fedora["trades"] = json!([
        sale,
        trade(
            "Mirelle",
            1760000200,
            "buy",
            "Linen Cloth",
            json!("2589"),
            1500,
            0
        )
    ]);
    call(&f.app, "POST", "/api/account", fedora.clone(), &f.auth()).await;
    let mac = log_in(&f.app, "K7Q2M9PX", "7KQ2M9PXABCDEFGHJKMN").await;
    assert_eq!(
        get(&f.app, "/api/account", &mac).await,
        json!({"id":"K7Q2M9PX","linked":[],"characters":[
            {"name":"Sultan","realm":"Faramon","faction":"Horde","class":"MAGE","level":60,"updatedAt":1791970261_u64,"gold":2}
        ]}),
        "before linking, each ID has only what its own computer uploaded"
    );

    assert_eq!(
        link(&f.app, None, "ABCDEFGH", "ABCDEFGHJKMNPQRSTVWX")
            .await
            .0,
        401
    );
    let (status, _, error) = link(&f.app, Some(&mac), "ABCDEFGH", "ABCDEFGHJKMNPQRSTVWY").await;
    assert_eq!((status, error), (403, json!({"error":"wrong ID or key"})));
    let (status, _, linked) =
        link(&f.app, Some(&mac), "abcd-efgh", "abcde-fghjk-mnpqr-stvwx").await;
    assert_eq!((status, linked), (200, json!({"linked":["ABCDEFGH"]})));
    assert_eq!(
        link(&f.app, Some(&mac), "ABCDEFGH", "ABCDEFGHJKMNPQRSTVWX")
            .await
            .2,
        json!({"linked":["ABCDEFGH"]}),
        "linking twice changes nothing"
    );

    let merged = json!([
        {"name":"Sultan","realm":"Faramon","faction":"Horde","class":"MAGE","level":61,"updatedAt":1791980000_u64,"gold":90},
        {"name":"Mirelle","realm":"Faramon","faction":"Horde","class":"PRIEST","level":20,"updatedAt":1791900000_u64,"gold":5}
    ]);
    assert_eq!(
        get(&f.app, "/api/account", &mac).await,
        json!({"id":"K7Q2M9PX","linked":["ABCDEFGH"],"characters":merged})
    );
    let other = log_in(&f.app, "ABCDEFGH", "ABCDEFGHJKMNPQRSTVWX").await;
    assert_eq!(
        get(&f.app, "/api/account", &other).await,
        json!({"id":"ABCDEFGH","linked":["K7Q2M9PX"],"characters":merged}),
        "either ID logs in to the same characters"
    );
    let sultan = get(&f.app, "/api/character?name=Sultan&realm=Faramon", &mac).await;
    assert_eq!(
        sultan["gold"],
        json!([
            [1791846000_u64, 50],
            [1791932400_u64, 7],
            [1792018800_u64, 90]
        ]),
        "gold from both computers, the newer upload winning an hour both have"
    );
    assert_eq!(
        (sultan["level"].clone(), sultan["bags"].clone()),
        (json!(61), json!({"at":1791980000_u64,"rows":[],"total":0}))
    );
    assert_eq!(
        get(&f.app, "/api/character?name=Mirelle&realm=Faramon", &mac).await["gold"],
        json!([[1791932400_u64, 5]])
    );
    let trades = get(&f.app, "/api/trades", &mac).await["trades"].clone();
    assert_eq!(
        trades
            .as_array()
            .unwrap()
            .iter()
            .map(|t| (t["name"].as_str().unwrap(), t["side"].as_str().unwrap()))
            .collect::<Vec<_>>(),
        [("Mirelle", "buy"), ("Sultan", "sell")],
        "a trade both computers booked counts once"
    );

    fedora["characters"].as_array_mut().unwrap().pop();
    call(&f.app, "POST", "/api/account", fedora, &f.auth()).await;
    assert_eq!(
        get(&f.app, "/api/account", &mac).await["characters"]
            .as_array()
            .unwrap()
            .len(),
        1,
        "an upload still replaces the characters of its own ID"
    );

    let mut third = account();
    third["id"] = json!("PQRSTVWX");
    third["keyHash"] = json!(goldbook_core::key_hash("PQRSTVWXABCDEFGHJKMN"));
    third["characters"][0]["name"] = json!("Thorn");
    call(&f.app, "POST", "/api/account", third, &f.auth()).await;
    let third = log_in(&f.app, "PQRSTVWX", "PQRSTVWXABCDEFGHJKMN").await;
    assert_eq!(
        link(&f.app, Some(&third), "K7Q2M9PX", "7KQ2M9PXABCDEFGHJKMN")
            .await
            .2,
        json!({"linked":["ABCDEFGH","K7Q2M9PX"]}),
        "linking one ID of a group brings the whole group"
    );
    assert_eq!(
        get(&f.app, "/api/account", &other).await["linked"],
        json!(["K7Q2M9PX", "PQRSTVWX"])
    );

    for _ in 0..5 {
        assert_eq!(
            link(&f.app, Some(&mac), "MNPQRSTV", "ABCDEFGHJKMNPQRSTVWX")
                .await
                .0,
            403
        );
    }
    assert_eq!(
        link(&f.app, Some(&mac), "MNPQRSTV", "ABCDEFGHJKMNPQRSTVWX")
            .await
            .0,
        429,
        "wrong keys count against the login limits"
    );
}
#[tokio::test]
async fn concurrent_claims_cannot_replace_another_owners_account() {
    let f = Fixture::new().await;
    let mut other = account();
    other["keyHash"] = json!(goldbook_core::key_hash("ABCDEFGHJKMNPQRSTVWX"));
    let auth = f.auth();
    let (a, b) = tokio::join!(
        call(&f.app, "POST", "/api/account", account(), &auth),
        call(&f.app, "POST", "/api/account", other, &auth)
    );
    let mut statuses = [a.0, b.0];
    statuses.sort();
    assert_eq!(statuses, [200, 409]);
    let db = db::connect(&f.database()).unwrap();
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM accounts", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM characters", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
}
#[tokio::test]
async fn desktop_handoff_csrf_body_limits_and_login_limits_are_enforced() {
    let f = Fixture::new().await;
    call(&f.app, "POST", "/api/account", account(), &f.auth()).await;
    let form = b"id=K7Q2M9PX&key=7KQ2M9PXABCDEFGHJKMN".to_vec();
    let headers = [
        ("content-type", "application/x-www-form-urlencoded"),
        ("origin", "http://127.0.0.1:49152"),
    ];
    let (status, cookies, body) =
        raw(&f.app, "POST", "/api/desktop-login", form.clone(), &headers).await;
    assert_eq!(status, 303);
    assert_eq!(cookies["location"], "../#characters");
    assert_eq!(cookies["cache-control"], "no-store");
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap(),
        json!({"id":"K7Q2M9PX"})
    );
    for (query, location) in [
        ("?view=bags", "../#bags"),
        ("?view=items", "../#items"),
        ("?view=Bags", "../#characters"),
        ("?view=%2F%2Fevil.example", "../#characters"),
        ("?view=bags%0D%0Aset-cookie:x", "../#characters"),
        ("?view=", "../#characters"),
    ] {
        let (status, headers, _) = raw(
            &f.app,
            "POST",
            &format!("/api/desktop-login{query}"),
            form.clone(),
            &headers,
        )
        .await;
        assert_eq!(
            (status, &headers["location"]),
            (303, &location.parse().unwrap()),
            "{query}"
        );
    }
    assert_eq!(
        raw(&f.app, "POST", "/api/login", form.clone(), &headers)
            .await
            .0,
        415
    );
    assert_eq!(
        raw(
            &f.app,
            "POST",
            "/api/desktop-login",
            form,
            &[("origin", "http://127.0.0.1.evil:80")]
        )
        .await
        .0,
        403
    );
    assert_eq!(
        raw(
            &f.app,
            "POST",
            "/api/login",
            vec![b'x'; 4097],
            &[("content-type", "application/json")]
        )
        .await
        .0,
        413
    );
    for _ in 0..5 {
        assert_eq!(
            call(
                &f.app,
                "POST",
                "/api/login",
                json!({"id":"K7Q2M9PX","key":"ABCDEFGHJKMNPQRSTVWX"}),
                &[]
            )
            .await
            .0,
            401
        );
    }
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/login",
            json!({"id":"K7Q2M9PX","key":"7KQ2M9PXABCDEFGHJKMN"}),
            &[]
        )
        .await
        .0,
        429
    );
}
#[tokio::test]
async fn static_head_and_error_contracts_are_preserved() {
    let f = Fixture::new().await;
    let (status, headers, body) = raw(&f.app, "HEAD", "/", vec![], &[]).await;
    assert_eq!(status, 200);
    assert!(body.is_empty());
    assert_eq!(headers["cache-control"], "no-cache");
    let (status, headers, body) = raw(&f.app, "HEAD", "/api/realms", vec![], &[]).await;
    assert_eq!(status, 404);
    assert_eq!(headers["content-length"], "21");
    assert!(body.is_empty());
    assert_eq!(
        raw(&f.app, "GET", "/../server/app.py", vec![], &[]).await.0,
        404
    );
    assert_eq!(
        call(
            &f.app,
            "GET",
            "/api/prices?realm=R&faction=H&limit=201",
            Value::Null,
            &[]
        )
        .await
        .2,
        json!({"error":"limit must be an integer from 0 to 200"})
    );
    assert_eq!(
        raw(
            &f.app,
            "POST",
            "/api/scans",
            b"{bad json".to_vec(),
            &f.auth()
        )
        .await
        .0,
        400
    );
    assert_eq!(raw(&f.app, "POST", "/api/scans", vec![], &[]).await.0, 401);
}
#[tokio::test]
async fn upgrading_a_python_database_preserves_ids_prices_and_retry_identity() {
    // The schema immediately before Python's fingerprint migration, with a scan.
    let f = Fixture::build(|database| {
        migrated_until(database, "0005").execute_batch("INSERT INTO scans VALUES (7,'Faramon','Horde','EU',1760000000,'replicate','Sultan','1.60.1.70338',2,1760000010); INSERT INTO prices VALUES (7,'2589',110,125,42,3),(7,'7070',300,320,5,2);").unwrap();
    })
    .await;
    let db = db::connect(&f.database()).unwrap();
    assert_eq!(
        call(&f.app, "POST", "/api/scans", scan(), &f.auth())
            .await
            .2,
        json!({"stored":false,"items":2})
    );
    assert_eq!(
        db.query_row("SELECT id FROM scans", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        7
    );
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM prices", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        2
    );
    assert!(
        db::query(&db, "PRAGMA foreign_key_check", &[])
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn upgrading_to_accounting_keeps_the_trades_booked_before() {
    let f = Fixture::new().await;
    let mut upload = account();
    upload["trades"] = json!([trade(
        "Sultan",
        1760000600,
        "vendor",
        "Broken Fang",
        json!(null),
        85,
        0
    )]);
    call(&f.app, "POST", "/api/account", upload.clone(), &f.auth()).await;
    // Rebuilding with the vendor migration again leaves the table as it was before accounting.
    let mut db = db::connect(&f.database()).unwrap();
    db.execute_batch(include_str!(
        "../../../server/migrations/0008_vendor_trades.sql"
    ))
    .unwrap();
    db.execute_batch("DELETE FROM migrations WHERE name='0012_accounting.sql'")
        .unwrap();
    assert!(
        db.execute("INSERT INTO trades (account_id,name,realm,at,side,item,count,price,fee,copy) VALUES ('K7Q2M9PX','Sultan','Faramon',1760000700,'quest','Q',1,1,0,0)", [])
            .is_err()
    );
    db::migrate(&mut db).unwrap();
    let app = router(Config::new(f.database())).unwrap();
    upload["trades"] = json!([entry(
        1760000700,
        "quest",
        "The Defias Brotherhood",
        1,
        3500,
        None
    )]);
    assert_eq!(
        call(&app, "POST", "/api/account", upload, &f.auth())
            .await
            .0,
        200
    );
    let cookie = log_in(&app, "K7Q2M9PX", "7KQ2M9PXABCDEFGHJKMN").await;
    assert_eq!(
        get(&app, "/api/trades", &cookie).await["trades"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| (
                t["side"].as_str().unwrap(),
                t["item"].as_str().unwrap(),
                t["party"].clone()
            ))
            .collect::<Vec<_>>(),
        [
            ("quest", "The Defias Brotherhood", Value::Null),
            ("vendor", "Broken Fang", Value::Null)
        ]
    );
}
#[tokio::test]
async fn json_surrogates_validate_at_original_length_then_match_python_storage() {
    let f = Fixture::new().await;
    let body = serde_json::to_string(&scan())
        .unwrap()
        .replace("\"Faramon\"", &format!("\"{}\\ud800\"", "a".repeat(63)));
    let (status, _, response) = raw(
        &f.app,
        "POST",
        "/api/scans",
        body.as_bytes().to_vec(),
        &f.auth(),
    )
    .await;
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&response));
    assert_eq!(
        raw(
            &f.app,
            "POST",
            "/api/scans",
            body.as_bytes().to_vec(),
            &f.auth()
        )
        .await
        .0,
        200
    );
    let db = db::connect(&f.database()).unwrap();
    let realm: String = db
        .query_row("SELECT realm FROM scans", [], |r| r.get(0))
        .unwrap();
    assert_eq!(realm, format!("{}���", "a".repeat(63)));
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM scans", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[tokio::test]
async fn explicit_web_directory_confines_files_and_overrides_embedded_assets() {
    let f = Fixture::new().await;
    let web = f.directory.join("web");
    std::fs::create_dir(&web).unwrap();
    std::fs::write(web.join("index.html"), b"custom index").unwrap();
    let mut config = Config::new(f.database());
    config.web_dir = Some(web);
    let app = router(config).unwrap();
    let (status, headers, body) = raw(&app, "GET", "/", vec![], &[]).await;
    assert_eq!(status, 200);
    assert_eq!(body, b"custom index");
    assert_eq!(headers["cache-control"], "no-cache");
    assert_eq!(
        raw(&app, "GET", "/../goldbook.sqlite", vec![], &[]).await.0,
        404
    );
    // Explicit WEB_DIR is authoritative; removed assets cannot fall back.
    assert_eq!(raw(&app, "GET", "/app.js", vec![], &[]).await.0, 404);
    let embedded = raw(&f.app, "GET", "/app.js", vec![], &[]).await;
    assert_eq!(embedded.0, 200);
    assert_eq!(embedded.2, include_bytes!("../../../web/app.js"));
}

#[tokio::test]
async fn embedded_fonts_are_served_as_woff2() {
    let f = Fixture::new().await;
    let fonts = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../web/fonts");
    let mut served = 0;
    for entry in std::fs::read_dir(fonts).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("woff2") {
            continue;
        }
        let name = path.file_name().unwrap().to_str().unwrap();
        let (status, headers, body) =
            raw(&f.app, "GET", &format!("/fonts/{name}"), vec![], &[]).await;
        assert_eq!(status, 200, "{name}");
        assert_eq!(headers["content-type"], "font/woff2", "{name}");
        assert_eq!(body, std::fs::read(&path).unwrap(), "{name}");
        served += 1;
    }
    assert_eq!(served, 4);
}

#[tokio::test]
async fn embedded_index_references_assets_by_content_version() {
    let f = Fixture::new().await;
    let (status, _, index) = raw(&f.app, "GET", "/", vec![], &[]).await;
    assert_eq!(status, 200);
    let index = String::from_utf8(index).unwrap();
    let reference = |name: &str| {
        let url = &index[index.find(&format!("\"{name}?v=")).unwrap() + 1..];
        url[..url.find('"').unwrap()].to_owned()
    };
    let assets: [(String, &str, &[u8]); 3] = [
        (
            reference("app.js"),
            "app.js?v=",
            include_bytes!("../../../web/app.js"),
        ),
        (
            reference("theme.js"),
            "theme.js?v=",
            include_bytes!("../../../web/theme.js"),
        ),
        (
            reference("style.css"),
            "style.css?v=",
            include_bytes!("../../../web/style.css"),
        ),
    ];
    for (url, prefix, expected) in assets {
        let version = url.strip_prefix(prefix).unwrap_or_default();
        assert!(
            version.len() == 12
                && version
                    .bytes()
                    .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')),
            "{url} is not {prefix} and 12 lowercase hex characters"
        );
        let (status, _, body) = raw(&f.app, "GET", &format!("/{url}"), vec![], &[]).await;
        assert_eq!(status, 200, "{url}");
        assert_eq!(body, expected, "{url}");
    }
}

#[tokio::test]
async fn update_feed_serves_public_files_and_ranges_without_exposing_the_database() {
    let fixture = Fixture::new().await;
    let directory = fixture.directory.join("updates/revision");
    std::fs::create_dir_all(&directory).unwrap();
    std::fs::write(directory.join("client.exe"), b"signed-client-package").unwrap();
    let request = |url: &str| {
        Request::builder()
            .uri(url)
            .header("range", "bytes=0-5")
            .body(Body::empty())
            .unwrap()
    };
    let response = fixture
        .app
        .clone()
        .oneshot(request("/updates/revision/client.exe"))
        .await
        .unwrap();
    assert_eq!(response.status(), 206);
    assert_eq!(to_bytes(response.into_body(), 100).await.unwrap(), "signed");
    for path in [
        "/updates/../goldbook.sqlite",
        "/updates/%2e%2e/goldbook.sqlite",
    ] {
        let response = fixture.app.clone().oneshot(request(path)).await.unwrap();
        assert_eq!(response.status(), 404);
    }
}

#[tokio::test]
async fn installation_tokens_are_hashed_persistent_revocable_and_only_allow_uploads() {
    let f = Fixture::new().await;
    let session = f.session();
    let (status, headers, body) = call(
        &f.app,
        "POST",
        "/api/installations",
        registration("a"),
        &session,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(headers["cache-control"], "no-store");
    let token = body["token"].as_str().unwrap();
    assert!(token.starts_with("gb_"));
    assert_eq!(token.len(), 46);
    let authorization = format!("Bearer {token}");
    let auth = [("authorization", authorization.as_str())];
    let db = db::connect(&f.database()).unwrap();
    let stored: String = db
        .query_row(
            "SELECT token_hash FROM upload_tokens WHERE fingerprint=?1",
            ["a".repeat(64)],
            |row| row.get(0),
        )
        .unwrap();
    use sha2::{Digest, Sha256};
    assert_eq!(stored, hex::encode(Sha256::digest(token.as_bytes())));
    assert_ne!(stored, token);
    assert_eq!(
        call(&f.app, "POST", "/api/scans", scan(), &auth).await.0,
        200
    );
    assert_eq!(
        call(&f.app, "POST", "/api/account", account(), &auth)
            .await
            .0,
        200
    );
    let mut other = account();
    other["keyHash"] = json!(goldbook_core::key_hash("OTHERKEYABCDEFGHJKMN"));
    assert_eq!(
        call(&f.app, "POST", "/api/account", other, &auth).await.0,
        409
    );
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/login",
            json!({"id":"K7Q2M9PX","key":token}),
            &auth
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(&f.app, "GET", "/api/account", Value::Null, &auth)
            .await
            .0,
        401
    );
    for headers in [
        &[][..],
        &[(
            "authorization",
            "Bearer gb_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )][..],
        &[("authorization", "Bearer dev-token")][..],
        &session[..],
    ] {
        assert_eq!(
            call(&f.app, "POST", "/api/scans", scan(), headers).await.2,
            json!({"error":"invalid upload token"})
        );
    }
    // A token registered before uploads needed Battle.net no longer uploads.
    let unbound = format!("gb_{}", "b".repeat(43));
    db.execute(
        "INSERT INTO upload_identities (fingerprint) VALUES (?1)",
        ["b".repeat(64)],
    )
    .unwrap();
    db.execute(
        "INSERT INTO upload_tokens (token_hash,fingerprint,created_at) VALUES (?1,?2,0)",
        [
            hex::encode(Sha256::digest(unbound.as_bytes())),
            "b".repeat(64),
        ],
    )
    .unwrap();
    let refused = call(
        &f.app,
        "POST",
        "/api/scans",
        scan(),
        &[("authorization", &format!("Bearer {unbound}"))],
    )
    .await;
    assert_eq!(refused.0, 401);
    assert_eq!(refused.2, json!({"error":"Battle.net sign-in required"}));
    // Existing credentials survive a restart, also without Battle.net.
    let restarted = router(Config::new(f.database())).unwrap();
    assert_eq!(
        call(
            &restarted,
            "POST",
            "/api/installations",
            registration("a"),
            &session
        )
        .await
        .0,
        403
    );
    assert_eq!(
        call(&restarted, "POST", "/api/scans", scan(), &auth)
            .await
            .0,
        200
    );
    db.execute("UPDATE upload_tokens SET revoked_at=unixepoch()", [])
        .unwrap();
    assert_eq!(
        call(&f.app, "POST", "/api/scans", scan(), &auth).await.0,
        401
    );
    assert_eq!(
        call(&restarted, "POST", "/api/scans", scan(), &auth)
            .await
            .0,
        401
    );
}

fn registration(digit: &str) -> Value {
    json!({"fingerprint":digit.repeat(64),"fingerprintVersion":1})
}

#[tokio::test]
async fn registration_needs_battlenet_validates_bodies_and_limits_issuance() {
    let f = Fixture::new().await;
    let session = f.session();
    // Without Battle.net nobody registers, but registered tokens still upload.
    let plain = router(Config::new(f.database())).unwrap();
    assert_eq!(
        call(
            &plain,
            "POST",
            "/api/installations",
            registration("a"),
            &session
        )
        .await
        .0,
        403
    );
    assert_eq!(
        call(&plain, "POST", "/api/scans", scan(), &f.auth())
            .await
            .0,
        200
    );
    let app = router(battlenet(f.database())).unwrap();
    assert_eq!(
        call(&app, "POST", "/api/installations", registration("a"), &[])
            .await
            .0,
        401
    );
    for body in [json!(null), json!([]), json!({"token":"provided"})] {
        assert_eq!(
            call(&app, "POST", "/api/installations", body, &session)
                .await
                .0,
            400
        );
    }
    let json_session = [session[0], ("content-type", "application/json")];
    assert_eq!(
        raw(
            &app,
            "POST",
            "/api/installations",
            b"{".to_vec(),
            &json_session
        )
        .await
        .0,
        400
    );
    assert_eq!(
        raw(
            &app,
            "POST",
            "/api/installations",
            b"{}".to_vec(),
            &[session[0], ("content-type", "text/plain")]
        )
        .await
        .0,
        415
    );
    assert_eq!(
        raw(&app, "POST", "/api/installations", b"{}".to_vec(), &session)
            .await
            .0,
        415
    );
    assert_eq!(
        raw(
            &app,
            "POST",
            "/api/installations",
            vec![b' '; 4097],
            &json_session
        )
        .await
        .0,
        413
    );
    // Refused and invalid requests consume attempts too: five handler calls plus fifteen successes.
    for _ in 0..15 {
        assert_eq!(
            call(
                &app,
                "POST",
                "/api/installations",
                registration("a"),
                &session
            )
            .await
            .0,
            200
        );
    }
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/installations",
            registration("a"),
            &session
        )
        .await
        .0,
        429
    );
    let count: i64 = db::connect(&f.database())
        .unwrap()
        .query_row(
            "SELECT count(*) FROM upload_tokens WHERE fingerprint=?1",
            ["a".repeat(64)],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 15);
    // Registration limits are independent from login failures.
    assert_eq!(
        call(&app, "POST", "/api/login", json!({}), &[]).await.0,
        401
    );
    assert_eq!(
        call(&app, "POST", "/api/scans", scan(), &f.auth()).await.0,
        200
    );
}

#[tokio::test]
async fn fingerprint_blocks_cover_every_credential_and_future_registrations() {
    let f = Fixture::new().await;
    let session = f.session();
    let app = f.app.clone();
    let mut tokens = Vec::new();
    for digit in ["a", "a", "b"] {
        let reply = call(
            &app,
            "POST",
            "/api/installations",
            registration(digit),
            &session,
        )
        .await;
        assert_eq!(reply.0, 200);
        tokens.push(format!("Bearer {}", reply.2["token"].as_str().unwrap()));
    }
    assert_ne!(tokens[0], tokens[1]);
    let mut db = db::connect(&f.database()).unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .unwrap();
    tx.execute(
        "UPDATE upload_identities SET blocked_at=unixepoch() WHERE fingerprint=?1",
        ["a".repeat(64)],
    )
    .unwrap();
    // Issuance racing an administrator's write must observe the block after commit.
    let issuing_app = app.clone();
    let issuing_session = f.session.clone();
    let issuance = tokio::spawn(async move {
        call(
            &issuing_app,
            "POST",
            "/api/installations",
            registration("a"),
            &[("authorization", &issuing_session)],
        )
        .await
    });
    tokio::task::yield_now().await;
    tx.commit().unwrap();
    let denied = issuance.await.unwrap();
    assert_eq!(denied.0, 403);
    assert_eq!(denied.2, json!({"error":"this account is blocked"}));
    for token in &tokens[..2] {
        let denied = call(
            &app,
            "POST",
            "/api/scans",
            scan(),
            &[("authorization", token)],
        )
        .await;
        assert_eq!(denied.0, 403);
        assert_eq!(denied.2, json!({"error":"this account is blocked"}));
    }
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/scans",
            scan(),
            &[("authorization", &tokens[2])]
        )
        .await
        .0,
        200
    );
    assert_eq!(
        call(&app, "POST", "/api/scans", scan(), &f.auth()).await.0,
        200
    );
    let count: i64 = db
        .query_row(
            "SELECT count(*) FROM upload_tokens WHERE fingerprint IN (?1,?2)",
            ["a".repeat(64), "b".repeat(64)],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 3);
    db.execute(
        "UPDATE upload_identities SET blocked_at=NULL WHERE fingerprint=?1",
        ["a".repeat(64)],
    )
    .unwrap();
    for token in &tokens[..2] {
        assert_eq!(
            call(
                &app,
                "POST",
                "/api/scans",
                scan(),
                &[("authorization", token)]
            )
            .await
            .0,
            200
        );
    }
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/installations",
            registration("a"),
            &session
        )
        .await
        .0,
        200
    );
}

#[tokio::test]
async fn registration_requires_only_versioned_lowercase_account_fingerprints() {
    let f = Fixture::new().await;
    let session = f.session();
    let db = db::connect(&f.database()).unwrap();
    let identities = || -> i64 {
        db.query_row("SELECT count(*) FROM upload_identities", [], |row| {
            row.get(0)
        })
        .unwrap()
    };
    let before = identities();
    for invalid in [
        json!({}),
        json!({"fingerprint":"a".repeat(64)}),
        json!({"fingerprintVersion":1}),
        json!({"fingerprint":"a".repeat(64),"fingerprintVersion":2}),
        json!({"fingerprint":"a".repeat(64),"fingerprintVersion":"1"}),
        json!({"fingerprint":"a".repeat(64),"fingerprintVersion":1.0}),
        json!({"fingerprint":"A".repeat(64),"fingerprintVersion":1}),
        json!({"fingerprint":"g".repeat(64),"fingerprintVersion":1}),
        json!({"fingerprint":"a".repeat(63),"fingerprintVersion":1}),
        json!({"fingerprint":"a".repeat(65),"fingerprintVersion":1}),
        json!({"fingerprint":"a".repeat(64),"fingerprintVersion":1,"accountPath":"private/path"}),
    ] {
        assert_eq!(
            call(&f.app, "POST", "/api/installations", invalid, &session)
                .await
                .0,
            400
        );
    }
    assert_eq!(identities(), before);
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/installations",
            registration("f"),
            &session
        )
        .await
        .0,
        200
    );
}

#[tokio::test]
async fn seller_batches_require_auth_validate_atomically_and_deduplicate() {
    let f = Fixture::new().await;
    let first = json!({"realm":"Faramon","faction":"Horde","itemKey":"2770","scannedAt":1760000000,"offers":[]});
    let mut second = first.clone();
    second["itemKey"] = json!("2840");
    let batch = json!([first, second]);
    assert_eq!(
        call(&f.app, "POST", "/api/sellers/batch", batch.clone(), &[])
            .await
            .0,
        401
    );
    let mut invalid = batch.clone();
    invalid[1]["scannedAt"] = json!(0);
    assert_eq!(
        call(&f.app, "POST", "/api/sellers/batch", invalid, &f.auth())
            .await
            .0,
        400
    );
    let db = db::connect(&f.database()).unwrap();
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM seller_snapshots", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    db.execute_batch("CREATE TRIGGER reject_bar BEFORE INSERT ON seller_snapshots WHEN NEW.item_key='2840' BEGIN SELECT RAISE(ABORT,'test failure'); END;").unwrap();
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/sellers/batch",
            batch.clone(),
            &f.auth()
        )
        .await
        .0,
        500
    );
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM seller_snapshots", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    db.execute_batch("DROP TRIGGER reject_bar").unwrap();
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/sellers/batch",
            batch.clone(),
            &f.auth()
        )
        .await
        .2,
        json!({"stored":2,"received":2})
    );
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/sellers/batch",
            batch.clone(),
            &f.auth()
        )
        .await
        .2,
        json!({"stored":0,"received":2})
    );
    assert_eq!(
        call(&f.app, "POST", "/api/sellers", batch[0].clone(), &f.auth())
            .await
            .2,
        json!({"stored":false})
    );
    for body in [json!([]), json!(vec![batch[0].clone(); 101])] {
        assert_eq!(
            call(&f.app, "POST", "/api/sellers/batch", body, &f.auth())
                .await
                .0,
            400
        );
    }
}
// A price list's items as (key, lowest buyout, time of that price).
fn listed(prices: &Value) -> Vec<(String, i64, i64)> {
    prices["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| {
            (
                item["itemKey"].as_str().unwrap().to_owned(),
                item["minBuyout"].as_i64().unwrap(),
                item["scannedAt"].as_i64().unwrap(),
            )
        })
        .collect()
}
#[tokio::test]
async fn prices_list_every_scanned_item_at_its_newest_price() {
    let f = Fixture::new().await;
    let names = json!({"2589":["Linen Cloth",1],"7070":["Elemental Water",1],"14047":["Runecloth",1],"2592":["Wool Cloth",1]});
    for (at, rows) in [
        (
            1760000000,
            json!([["2589", 110, 0, 42, 3], ["7070", 300, 0, 5, 2]]),
        ),
        (
            1760100000,
            json!([["2589", 150, 0, 40, 3], ["14047", 900, 0, 20, 4]]),
        ),
        // Uploaded last, scanned first: it adds Wool Cloth but no newer price.
        (
            1759900000,
            json!([["7070", 999, 0, 1, 1], ["2592", 50, 0, 8, 2]]),
        ),
    ] {
        let mut upload = scan();
        upload["scannedAt"] = json!(at);
        upload["mode"] = json!("browse");
        upload["rows"] = rows;
        upload["items"] = names.clone();
        assert_eq!(
            call(&f.app, "POST", "/api/scans", upload, &f.auth())
                .await
                .0,
            200
        );
    }
    let (_, _, all) = call(
        &f.app,
        "GET",
        "/api/prices?realm=Faramon&faction=Horde",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(all["total"], 4);
    assert_eq!(
        all["scan"]["scannedAt"], 1760100000,
        "the scan named is still the newest"
    );
    assert_eq!(
        listed(&all),
        [
            ("7070".to_owned(), 300, 1760000000),
            ("2589".to_owned(), 150, 1760100000),
            ("14047".to_owned(), 900, 1760100000),
            ("2592".to_owned(), 50, 1759900000),
        ]
    );
    let (_, _, cloth) = call(
        &f.app,
        "GET",
        "/api/prices?realm=Faramon&faction=Horde&q=cloth&limit=1&offset=1",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(
        cloth["total"], 3,
        "Linen Cloth, Runecloth and Wool Cloth match"
    );
    assert_eq!(listed(&cloth), [("14047".to_owned(), 900, 1760100000)]);
    let (_, _, other) = call(
        &f.app,
        "GET",
        "/api/prices?realm=Faramon&faction=Alliance",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(other["error"], "no scans for this realm and faction");
}
#[tokio::test]
async fn upgrading_fills_the_newest_price_of_every_scanned_item() {
    // Scans stored before the newest-price table, the newer one first by id.
    let f = Fixture::build(|database| {
        migrated_until(database, "0015").execute_batch("INSERT INTO scans (id,realm,faction,region,scanned_at,mode,scanner,build,item_count,uploaded_at,fingerprint) VALUES (1,'Faramon','Horde','EU',1760100000,'browse','Sultan','1.60.1.70338',1,1760100010,'a'),(2,'Faramon','Horde','EU',1760000000,'browse','Sultan','1.60.1.70338',2,1760100020,'b'); INSERT INTO prices VALUES (1,'2589',150,0,40,3),(2,'2589',110,0,42,3),(2,'7070',300,0,5,2);").unwrap();
    })
    .await;
    let (_, _, prices) = call(
        &f.app,
        "GET",
        "/api/prices?realm=Faramon&faction=Horde&sort=min",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(prices["total"], 2);
    let listed: Vec<_> = prices["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| (item["itemKey"].clone(), item["minBuyout"].clone()))
        .collect();
    assert_eq!(
        listed,
        [(json!("2589"), json!(150)), (json!("7070"), json!(300))]
    );
}
fn forever_scan(realm: &str, at: i64, mode: &str, rows: Value, items: Value) -> Value {
    json!({"realm":realm,"faction":"Horde","region":"EU","scannedAt":at,"mode":mode,"scanner":"Feretuse","build":"1.60.1.70790","rows":rows,"items":items})
}
async fn upload(f: &Fixture, scan: Value) {
    let (status, _, body) = call(&f.app, "POST", "/api/scans", scan, &f.auth()).await;
    assert_eq!(status, 200, "{body}");
}
// The reported case: two shards of one WoW Forever house, scans on one only.
#[tokio::test]
async fn a_never_scanned_forever_shard_reads_its_house() {
    let f = Fixture::new().await;
    upload(
        &f,
        forever_scan(
            "CAMWOWEU4Realm8PvP",
            1760000000,
            "replicate",
            json!([["2589", 110, 125, 42, 3], ["7070", 300, 320, 5, 2]]),
            json!({"2589":["Linen Cloth",1],"7070":["Elemental Water",1]}),
        ),
    )
    .await;
    upload(
        &f,
        forever_scan(
            "CAMWOWEU4Realm8PvP",
            1760003600,
            "browse",
            json!([["2589", 100, 0, 10, 0]]),
            json!({}),
        ),
    )
    .await;
    let realm6 = "realm=CAMWOWEU4Realm6PvP&faction=Horde";
    let (status, _, export) = call(
        &f.app,
        "GET",
        &format!("/api/export?{realm6}"),
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(
        (status, export),
        (
            200,
            json!({
                "realm": "CAMWOWEU4Realm6PvP",
                "faction": "Horde",
                "scannedAt": 1760003600,
                "items": {
                    "2589": {
                        "name": "Linen Cloth",
                        "quality": 1,
                        "price": [100, 10, 0, 1760003600, 125, 1760000000],
                        "hours": [[488888, 110, 42, 125], [488889, 100, 10, 0]],
                        "days": [[20370, 100, 10, 125]]
                    },
                    "7070": {
                        "name": "Elemental Water",
                        "quality": 1,
                        "price": [300, 5, 2, 1760000000, 320, 1760000000],
                        "hours": [[488888, 300, 5, 320]],
                        "days": [[20370, 300, 5, 320]]
                    }
                }
            })
        )
    );
    let (status, _, prices) = call(
        &f.app,
        "GET",
        &format!("/api/prices?{realm6}"),
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(
        (status, &prices),
        (
            200,
            &json!({
                "scan": {"id": 2, "scannedAt": 1760003600, "mode": "browse", "itemCount": 1, "scanner": "Feretuse"},
                "marketScan": {"id": 1, "scannedAt": 1760000000, "mode": "replicate", "itemCount": 2, "scanner": "Feretuse"},
                "total": 2,
                "items": [
                    {"itemKey": "7070", "name": "Elemental Water", "quality": 1, "minBuyout": 300, "marketValue": 320, "marketScannedAt": 1760000000, "quantity": 5, "numAuctions": 2, "scannedAt": 1760000000},
                    {"itemKey": "2589", "name": "Linen Cloth", "quality": 1, "minBuyout": 100, "marketValue": 125, "marketScannedAt": 1760000000, "quantity": 10, "numAuctions": 0, "scannedAt": 1760003600}
                ]
            })
        )
    );
    let (_, _, history) = call(
        &f.app,
        "GET",
        &format!("/api/history?{realm6}&itemKey=2589"),
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(
        history,
        json!({
            "itemKey": "2589",
            "name": "Linen Cloth",
            "quality": 1,
            "points": [
                {"scannedAt": 1760000000, "mode": "replicate", "minBuyout": 110, "marketValue": 125, "quantity": 42},
                {"scannedAt": 1760003600, "mode": "browse", "minBuyout": 100, "marketValue": 0, "quantity": 10}
            ]
        })
    );
    // The other faction, another region and another ruleset are other houses.
    for other in [
        "realm=CAMWOWEU4Realm6PvP&faction=Alliance",
        "realm=CAMWOWUS4Realm6PvP&faction=Horde",
        "realm=CAMWOWEU4Realm6PvE&faction=Horde",
    ] {
        for endpoint in ["export", "prices"] {
            let (status, _, body) = call(
                &f.app,
                "GET",
                &format!("/api/{endpoint}?{other}"),
                Value::Null,
                &[],
            )
            .await;
            assert_eq!(
                (status, body),
                (404, json!({"error": "no scans for this realm and faction"})),
                "{endpoint}?{other}"
            );
        }
        let (_, _, history) = call(
            &f.app,
            "GET",
            &format!("/api/history?{other}&itemKey=2589"),
            Value::Null,
            &[],
        )
        .await;
        assert_eq!(history["points"], json!([]), "{other}");
    }
    let (_, _, realms) = call(&f.app, "GET", "/api/realms", Value::Null, &[]).await;
    assert_eq!(
        realms,
        json!({"realms": [{"realm": "EU PvP", "faction": "Horde", "region": "EU", "scans": 2, "lastScan": 1760003600}]})
    );
    // What /api/realms lists answers for itself, with the space sent as `+`
    // as the website sends it or as `%20`, and so does another EU cluster.
    for realm in ["EU+PvP", "EU%20PvP", "CAMWOWEU1Realm6PvP"] {
        let (_, _, same) = call(
            &f.app,
            "GET",
            &format!("/api/prices?realm={realm}&faction=Horde"),
            Value::Null,
            &[],
        )
        .await;
        assert_eq!(same, prices, "{realm}");
    }
    let (_, _, by_house) = call(
        &f.app,
        "GET",
        "/api/export?realm=EU%20PvP&faction=Horde",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(
        (&by_house["realm"], &by_house["scannedAt"]),
        (&json!("EU PvP"), &json!(1760003600))
    );
}
#[tokio::test]
async fn shards_of_one_house_list_each_item_once_at_its_newest_price() {
    let f = Fixture::new().await;
    let names = json!({"2589":["Linen Cloth",1],"7070":["Elemental Water",1],"14047":["Runecloth",1],"2592":["Wool Cloth",1]});
    for (realm, at, rows) in [
        (
            "CAMWOWEU4Realm8PvP",
            1760000000,
            json!([["2589", 120, 0, 30, 0], ["7070", 300, 0, 5, 0]]),
        ),
        (
            "CAMWOWEU4Realm6PvP",
            1760003600,
            json!([["2589", 90, 0, 20, 0], ["14047", 900, 0, 2, 0]]),
        ),
        // Uploaded last, scanned first: it adds Wool Cloth but no newer price.
        (
            "CAMWOWEU4Realm8PvP",
            1759990000,
            json!([["7070", 999, 0, 1, 0], ["2592", 50, 0, 8, 0]]),
        ),
    ] {
        upload(&f, forever_scan(realm, at, "browse", rows, names.clone())).await;
    }
    let (_, _, prices) = call(
        &f.app,
        "GET",
        "/api/prices?realm=CAMWOWEU4Realm8PvP&faction=Horde",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(prices["total"], 4);
    assert_eq!(
        prices["scan"],
        json!({"id": 2, "scannedAt": 1760003600, "mode": "browse", "itemCount": 2, "scanner": "Feretuse"}),
        "the house's newest scan is the other shard's"
    );
    assert_eq!(
        listed(&prices),
        [
            ("7070".to_owned(), 300, 1760000000),
            ("2589".to_owned(), 90, 1760003600),
            ("14047".to_owned(), 900, 1760003600),
            ("2592".to_owned(), 50, 1759990000),
        ]
    );
    let (_, _, cloth) = call(
        &f.app,
        "GET",
        "/api/prices?realm=CAMWOWEU4Realm8PvP&faction=Horde&q=cloth",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(cloth["total"], 3);
    let (_, _, export) = call(
        &f.app,
        "GET",
        "/api/export?realm=CAMWOWEU4Realm6PvP&faction=Horde",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(export["scannedAt"], 1760003600);
    assert_eq!(
        export["items"]
            .as_object()
            .unwrap()
            .keys()
            .collect::<Vec<_>>(),
        ["14047", "2589", "2592", "7070"]
    );
    assert_eq!(
        export["items"]["2589"],
        json!({
            "name": "Linen Cloth",
            "quality": 1,
            "price": [90, 20, 0, 1760003600, 0, 0],
            "hours": [[488888, 120, 30, 0], [488889, 90, 20, 0]],
            "days": [[20370, 90, 20, 0]]
        })
    );
    let (_, _, trends) = call(
        &f.app,
        "GET",
        "/api/trends?realm=CAMWOWEU4Realm6PvP&faction=Horde&items=2589,7070",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(trends["days"][13], 1759968000);
    assert_eq!(
        trends["items"],
        json!({
            "2589": [null, null, null, null, null, null, null, null, null, null, null, null, null, 90],
            "7070": [null, null, null, null, null, null, null, null, null, null, null, null, null, 300]
        })
    );
}
#[tokio::test]
async fn seller_snapshots_answer_by_house() {
    let f = Fixture::new().await;
    for (realm, at) in [
        ("CAMWOWEU4Realm8PvP", 1760000000),
        ("CAMWOWEU4Realm6PvP", 1760003600),
    ] {
        let snapshot =
            json!({"realm":realm,"faction":"Horde","itemKey":"2589","scannedAt":at,"offers":[]});
        assert_eq!(
            call(&f.app, "POST", "/api/sellers", snapshot, &f.auth())
                .await
                .2,
            json!({"stored": true})
        );
    }
    let (_, _, sellers) = call(
        &f.app,
        "GET",
        "/api/sellers?realm=CAMWOWEU4Realm8PvP&faction=Horde&itemKey=2589&history=1",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(sellers["snapshot"]["scannedAt"], 1760003600);
    assert_eq!(
        sellers["history"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["scannedAt"].as_i64().unwrap())
            .collect::<Vec<_>>(),
        [1760003600, 1760000000]
    );
    let (_, _, none) = call(
        &f.app,
        "GET",
        "/api/sellers?realm=CAMWOWEU4Realm8PvP&faction=Alliance&itemKey=2589",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(none, json!({"snapshot": null}));
}
// A deployment's database from before auction houses, where every row is its
// realm's own: the first start moves the Forever shards into their house and
// leaves other realms alone, and a later start moves nothing.
#[tokio::test]
async fn the_first_start_moves_stored_forever_shards_into_their_house() {
    let f = Fixture::build(|database| {
        migrated_until(database, "0016").execute_batch(r#"
            INSERT INTO scans (id,realm,faction,region,scanned_at,mode,scanner,build,item_count,uploaded_at,fingerprint) VALUES
              (1,'CAMWOWEU4Realm8PvP','Horde','EU',1760000000,'browse','Feretuse','1.60.1.70790',2,1760000010,'a'),
              (2,'CAMWOWEU4Realm6PvP','Horde','EU',1760003600,'browse','Feretuse','1.60.1.70790',1,1760003610,'b'),
              (3,'Faramon','Horde','EU',1760000000,'browse','Sultan','1.60.1.70338',1,1760000010,'c');
            INSERT INTO prices VALUES (1,'2589',120,0,30,0),(1,'7070',300,0,5,0),(2,'2589',90,0,20,0),(3,'2589',110,0,42,3);
            INSERT INTO latest_prices VALUES ('CAMWOWEU4Realm8PvP','Horde','2589',1),('CAMWOWEU4Realm8PvP','Horde','7070',1),('CAMWOWEU4Realm6PvP','Horde','2589',2),('Faramon','Horde','2589',3);
            INSERT INTO seller_snapshots VALUES
              ('d','CAMWOWEU4Realm8PvP','Horde','2589',1760000000,'{"realm":"CAMWOWEU4Realm8PvP","faction":"Horde","itemKey":"2589","scannedAt":1760000000,"offers":[]}'),
              ('e','Faramon','Horde','2589',1760007200,'{"realm":"Faramon","faction":"Horde","itemKey":"2589","scannedAt":1760007200,"offers":[]}');
        "#).unwrap();
    })
    .await;
    let get = |target: String| {
        let app = f.app.clone();
        async move { call(&app, "GET", &target, Value::Null, &[]).await.2 }
    };
    let realms: Vec<_> = get("/api/realms".into()).await["realms"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["realm"].as_str().unwrap().to_owned(),
                r["scans"].as_i64().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        realms,
        [("EU PvP".to_owned(), 2), ("Faramon".to_owned(), 1)]
    );
    for realm in ["CAMWOWEU4Realm6PvP", "CAMWOWEU4Realm8PvP", "EU%20PvP"] {
        assert_eq!(
            listed(&get(format!("/api/prices?realm={realm}&faction=Horde")).await),
            [
                ("2589".to_owned(), 90, 1760003600),
                ("7070".to_owned(), 300, 1760000000)
            ],
            "{realm}"
        );
        assert_eq!(
            get(format!(
                "/api/sellers?realm={realm}&faction=Horde&itemKey=2589"
            ))
            .await["snapshot"]["scannedAt"],
            1760000000,
            "{realm}"
        );
    }
    assert_eq!(
        listed(&get("/api/prices?realm=Faramon&faction=Horde".into()).await),
        [("2589".to_owned(), 110, 1760000000)]
    );
    assert_eq!(
        get("/api/sellers?realm=Faramon&faction=Horde&itemKey=2589".into()).await["snapshot"]["scannedAt"],
        1760007200
    );
    let mut db = db::connect(&f.database()).unwrap();
    assert_eq!(
        goldbook_server::house::reconcile(&mut db).unwrap(),
        goldbook_server::house::Reconciled::default(),
        "a second start moves nothing"
    );
}

// A snapshot as Battle.net serves it: its Last-Modified as Battle.net writes
// it, the same time as the IMF-fixdate a client sends back, and its two lists.
struct Snapshot {
    modified: &'static str,
    since: &'static str,
    regular: Value,
    commodities: Value,
}
// The Battle.net API and token endpoint, with auctions for EU house 113 only.
struct Blizzard {
    snapshot: Snapshot,
    // The API accepts only `token-<revision>`, which the token endpoint grants.
    revision: usize,
    granted: usize,
    honors_since: bool,
    // How many more commodity requests still get the first snapshot's list.
    stale_commodities: usize,
    // The If-Modified-Since and Accept-Encoding of each request for house 113.
    asked: Vec<(Option<String>, String)>,
    // The item API's namespace, item ID, name and quality type of each item
    // it knows, and the namespace and item ID of each request it got.
    items: Vec<(&'static str, u64, &'static str, &'static str)>,
    looked_up: Vec<(&'static str, u64)>,
    // The namespace and item ID whose lookups fail, and what runs during the
    // next lookup.
    failing: Option<(&'static str, u64)>,
    meanwhile: Option<Box<dyn FnOnce() + Send>>,
}
const FOREVER: &str = "static-forever-eu";
const CLASSIC_ERA: &str = "static-classic1x-eu";
fn first_snapshot() -> Snapshot {
    Snapshot {
        modified: "Fri, 6 Nov 2026 09:17:22 GMT",
        since: "Fri, 06 Nov 2026 09:17:22 GMT",
        regular: json!({"_links":{},"id":113,"name":"Horde","auctions":[
            {"id":1,"item":{"id":2589},"buyout":120,"quantity":1,"time_left":"LONG"},
            {"id":2,"item":{"id":2589},"buyout":100,"quantity":1,"time_left":"LONG"},
            {"id":3,"item":{"id":2589},"buyout":101,"quantity":1,"time_left":"SHORT"},
            {"id":4,"item":{"id":2589},"buyout":400,"bid":350,"quantity":1,"time_left":"LONG"},
            {"id":5,"item":{"id":15477,"bonus_lists":[12725]},"buyout":300,"quantity":1,"time_left":"LONG"},
            {"id":6,"item":{"id":15477},"buyout":500,"quantity":1,"time_left":"LONG"},
            {"id":7,"item":{"id":9999},"bid":50,"quantity":1,"time_left":"LONG"}
        ]}),
        commodities: json!({"_links":{},"auctions":[
            {"id":10,"item":{"id":4537},"quantity":20,"unit_price":50,"time_left":"VERY_LONG"},
            {"id":11,"item":{"id":4537},"quantity":5,"unit_price":45,"time_left":"SHORT"},
            {"id":12,"item":{"id":4537},"quantity":100,"unit_price":80,"time_left":"LONG"}
        ]}),
    }
}
fn second_snapshot() -> Snapshot {
    Snapshot {
        modified: "Fri, 6 Nov 2026 10:17:22 GMT",
        since: "Fri, 06 Nov 2026 10:17:22 GMT",
        regular: json!({"_links":{},"id":113,"name":"Horde","auctions":[
            {"id":20,"item":{"id":2589},"buyout":95,"quantity":1,"time_left":"LONG"},
            {"id":21,"item":{"id":2589},"buyout":90,"quantity":1,"time_left":"LONG"}
        ]}),
        commodities: json!({"_links":{},"auctions":[
            {"id":22,"item":{"id":4537},"quantity":10,"unit_price":44,"time_left":"LONG"}
        ]}),
    }
}
async fn blizzard(
    axum::extract::State(state): axum::extract::State<Arc<Mutex<Blizzard>>>,
    request: Request<Body>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    use std::io::Write;
    let (parts, body) = request.into_parts();
    let header = |name| {
        parts
            .headers
            .get(name)
            .map(|value: &axum::http::HeaderValue| value.to_str().unwrap().to_owned())
    };
    let body = to_bytes(body, 4096).await.unwrap();
    let mut state = state.lock().unwrap();
    if parts.uri.path() == "/token" {
        assert_eq!(parts.method, "POST");
        assert_eq!(
            header("authorization").as_deref(),
            Some("Basic Y2xpZW50OnNlY3JldA==")
        );
        assert_eq!(&body[..], b"grant_type=client_credentials");
        state.granted += 1;
        let token = format!("token-{}", state.revision);
        return axum::Json(json!({"access_token":token,"token_type":"bearer","expires_in":86399}))
            .into_response();
    }
    if header("authorization") != Some(format!("Bearer token-{}", state.revision)) {
        return axum::http::StatusCode::UNAUTHORIZED.into_response();
    }
    if let Some(item) = parts.uri.path().strip_prefix("/data/wow/item/") {
        let query = parts.uri.query().unwrap_or_default();
        let namespace = [FOREVER, CLASSIC_ERA]
            .into_iter()
            .find(|namespace| query == format!("namespace={namespace}&locale=en_US"))
            .unwrap_or_else(|| panic!("{query}"));
        let item: u64 = item.parse().unwrap();
        state.looked_up.push((namespace, item));
        if let Some(meanwhile) = state.meanwhile.take() {
            meanwhile();
        }
        if state.failing == Some((namespace, item)) {
            return axum::http::StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
        return match state
            .items
            .iter()
            .find(|known| (known.0, known.1) == (namespace, item))
        {
            Some((_, id, name, quality)) => {
                axum::Json(json!({"_links":{},"id":id,"name":name,"quality":{"type":quality}}))
                    .into_response()
            }
            None => axum::http::StatusCode::NOT_FOUND.into_response(),
        };
    }
    assert_eq!(parts.uri.query(), Some("namespace=dynamic-forever-eu"));
    let (list, modified) = match parts.uri.path() {
        "/data/wow/ruleset/1/auctions/113" => {
            let since = header("if-modified-since");
            state
                .asked
                .push((since.clone(), header("accept-encoding").unwrap_or_default()));
            if state.honors_since && since.as_deref() == Some(state.snapshot.since) {
                return axum::http::StatusCode::NOT_MODIFIED.into_response();
            }
            (state.snapshot.regular.clone(), state.snapshot.modified)
        }
        "/data/wow/ruleset/1/auctions/113/commodities" if state.stale_commodities > 0 => {
            state.stale_commodities -= 1;
            let first = first_snapshot();
            (first.commodities, first.modified)
        }
        "/data/wow/ruleset/1/auctions/113/commodities" => {
            (state.snapshot.commodities.clone(), state.snapshot.modified)
        }
        _ => return axum::http::StatusCode::NOT_FOUND.into_response(),
    };
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(list.to_string().as_bytes()).unwrap();
    (
        [
            ("content-type", "application/json;charset=UTF-8"),
            ("content-encoding", "gzip"),
            ("last-modified", modified),
        ],
        encoder.finish().unwrap(),
    )
        .into_response()
}
// A poller against a loopback Battle.net that serves `snapshot`.
async fn battlenet_poller(f: &Fixture) -> (Poller, Arc<Mutex<Blizzard>>) {
    battlenet_poller_with(f, |_| {}).await
}
async fn battlenet_poller_with(
    f: &Fixture,
    configure: impl FnOnce(&mut AuctionConfig),
) -> (Poller, Arc<Mutex<Blizzard>>) {
    let state = Arc::new(Mutex::new(Blizzard {
        snapshot: first_snapshot(),
        revision: 1,
        granted: 0,
        honors_since: true,
        stale_commodities: 0,
        asked: vec![],
        items: vec![],
        looked_up: vec![],
        failing: None,
        meanwhile: None,
    }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let api = Router::new().fallback(blizzard).with_state(state.clone());
    tokio::spawn(async move { axum::serve(listener, api).await.unwrap() });
    let mut config = AuctionConfig::parse("1", "client", "secret")
        .unwrap()
        .unwrap();
    config.token_endpoint = format!("{origin}/token");
    config.api = origin;
    config.retry_pause = std::time::Duration::ZERO;
    configure(&mut config);
    let database = f.database();
    let poller = tokio::task::spawn_blocking(move || Poller::new(config, database).unwrap())
        .await
        .unwrap();
    (poller, state)
}
// The blocking client must not run, or drop, on the async runtime.
async fn poll(mut poller: Poller) -> Poller {
    tokio::task::spawn_blocking(move || {
        poller.poll_once();
        poller
    })
    .await
    .unwrap()
}
async fn stop(poller: Poller) {
    tokio::task::spawn_blocking(move || drop(poller))
        .await
        .unwrap();
}
async fn horde_export(f: &Fixture) -> Value {
    let (status, _, body) = call(
        &f.app,
        "GET",
        "/api/export?realm=CAMWOWEU4Realm8PvP&faction=Horde",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(status, 200, "{body}");
    body
}
async fn stored_scans(f: &Fixture) -> Value {
    call(&f.app, "GET", "/api/realms", Value::Null, &[]).await.2["realms"].clone()
}
// Each item of the EU PvP Horde export as its name, its quality and where the
// server got the name.
async fn horde_names(f: &Fixture) -> Value {
    use rusqlite::OptionalExtension;
    let db = db::connect(&f.database()).unwrap();
    let export = horde_export(f).await;
    let names = export["items"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(key, item)| {
            let source: Option<String> = db
                .query_row("SELECT source FROM items WHERE item_key=?1", [key], |row| {
                    row.get(0)
                })
                .optional()
                .unwrap();
            (key.clone(), json!([item["name"], item["quality"], source]))
        });
    Value::Object(names.collect())
}

#[tokio::test]
async fn battlenet_snapshots_reach_the_export_once_each() {
    let f = Fixture::new().await;
    let (poller, blizzard) = battlenet_poller(&f).await;

    let poller = poll(poller).await;
    let export = horde_export(&f).await;
    assert_eq!(export["scannedAt"], 1793956642);
    assert_eq!(
        export["items"],
        json!({
            "2589":{"name":null,"quality":null,"price":[100,4,4,1793956642,101,1793956642],"hours":[[498321,100,4,101]],"days":[[20763,100,4,101]]},
            "4537":{"name":null,"quality":null,"price":[45,125,3,1793956642,50,1793956642],"hours":[[498321,45,125,50]],"days":[[20763,45,125,50]]},
            "15477":{"name":null,"quality":null,"price":[500,1,1,1793956642,500,1793956642],"hours":[[498321,500,1,500]],"days":[[20763,500,1,500]]}
        })
    );
    assert_eq!(
        stored_scans(&f).await,
        json!([{"realm":"EU PvP","faction":"Horde","region":"EU","scans":1,"lastScan":1793956642}])
    );

    let poller = poll(poller).await;
    // Another cached copy of the same snapshot, one listing apart, from a
    // server that ignores If-Modified-Since.
    {
        let mut blizzard = blizzard.lock().unwrap();
        blizzard.honors_since = false;
        blizzard.snapshot.regular["auctions"]
            .as_array_mut()
            .unwrap()
            .push(json!({"id":8,"item":{"id":2589},"buyout":99,"quantity":1,"time_left":"LONG"}));
    }
    let poller = poll(poller).await;
    assert_eq!(
        stored_scans(&f).await,
        json!([{"realm":"EU PvP","faction":"Horde","region":"EU","scans":1,"lastScan":1793956642}])
    );

    blizzard.lock().unwrap().snapshot = second_snapshot();
    let poller = poll(poller).await;
    let poller = poll(poller).await;
    assert_eq!(
        stored_scans(&f).await,
        json!([{"realm":"EU PvP","faction":"Horde","region":"EU","scans":2,"lastScan":1793960242}])
    );
    let export = horde_export(&f).await;
    assert_eq!(export["scannedAt"], 1793960242);
    assert_eq!(
        export["items"],
        json!({
            "2589":{"name":null,"quality":null,"price":[90,2,2,1793960242,90,1793960242],"hours":[[498321,100,4,101],[498322,90,2,90]],"days":[[20763,90,2,90]]},
            "4537":{"name":null,"quality":null,"price":[44,10,1,1793960242,44,1793960242],"hours":[[498321,45,125,50],[498322,44,10,44]],"days":[[20763,44,10,44]]},
            "15477":{"name":null,"quality":null,"price":[500,1,1,1793956642,500,1793956642],"hours":[[498321,500,1,500]],"days":[[20763,500,1,500]]}
        })
    );

    let asked: Vec<_> = blizzard
        .lock()
        .unwrap()
        .asked
        .iter()
        .map(|(since, encoding)| (since.clone(), encoding.contains("gzip")))
        .collect();
    let since = |at: &str| (Some(at.to_owned()), true);
    assert_eq!(
        asked,
        [
            (None, true),
            since("Fri, 06 Nov 2026 09:17:22 GMT"),
            since("Fri, 06 Nov 2026 09:17:22 GMT"),
            since("Fri, 06 Nov 2026 09:17:22 GMT"),
            since("Fri, 06 Nov 2026 10:17:22 GMT"),
        ]
    );
    assert_eq!(blizzard.lock().unwrap().granted, 1);
    stop(poller).await;
}

#[tokio::test]
async fn a_refused_token_is_replaced_and_the_snapshot_still_stored() {
    let f = Fixture::new().await;
    let (poller, blizzard) = battlenet_poller(&f).await;
    let poller = poll(poller).await;
    {
        let mut blizzard = blizzard.lock().unwrap();
        blizzard.revision = 2;
        blizzard.snapshot = second_snapshot();
    }
    let poller = poll(poller).await;
    let poller = poll(poller).await;
    assert_eq!(
        stored_scans(&f).await,
        json!([{"realm":"EU PvP","faction":"Horde","region":"EU","scans":2,"lastScan":1793960242}])
    );
    assert_eq!(blizzard.lock().unwrap().granted, 2);
    stop(poller).await;
}

#[tokio::test]
async fn a_snapshot_published_between_the_two_lists_is_fetched_again() {
    let f = Fixture::new().await;
    let (poller, blizzard) = battlenet_poller(&f).await;
    {
        let mut blizzard = blizzard.lock().unwrap();
        blizzard.snapshot = second_snapshot();
        blizzard.stale_commodities = 3;
    }
    let poller = poll(poller).await;
    assert_eq!(stored_scans(&f).await, json!([]));

    let poller = poll(poller).await;
    assert_eq!(
        stored_scans(&f).await,
        json!([{"realm":"EU PvP","faction":"Horde","region":"EU","scans":1,"lastScan":1793960242}])
    );
    assert_eq!(
        horde_export(&f).await["items"],
        json!({
            "2589":{"name":null,"quality":null,"price":[90,2,2,1793960242,90,1793960242],"hours":[[498322,90,2,90]],"days":[[20763,90,2,90]]},
            "4537":{"name":null,"quality":null,"price":[44,10,1,1793960242,44,1793960242],"hours":[[498322,44,10,44]],"days":[[20763,44,10,44]]}
        })
    );
    stop(poller).await;
}

#[tokio::test]
async fn variants_keep_the_market_value_players_measured_after_a_snapshot() {
    let f = Fixture::new().await;
    upload(
        &f,
        forever_scan(
            "CAMWOWEU4Realm8PvP",
            1793950000,
            "replicate",
            json!([["15477:584", 700, 600, 1, 1], ["2589", 120, 110, 3, 2]]),
            json!({"15477:584":["Bandit Cinch of the Monkey",2],"2589":["Linen Cloth",1]}),
        ),
    )
    .await;
    upload(
        &f,
        forever_scan(
            "CAMWOWEU4Realm8PvP",
            1793960000,
            "browse",
            json!([["15477:584", 650, 0, 1, 0], ["2589", 95, 0, 7, 0]]),
            json!({}),
        ),
    )
    .await;
    async fn market(f: &Fixture) -> Vec<(String, i64, i64, Value)> {
        let (status, _, body) = call(
            &f.app,
            "GET",
            "/api/prices?realm=CAMWOWEU4Realm8PvP&faction=Horde&sort=market&order=desc",
            Value::Null,
            &[],
        )
        .await;
        assert_eq!(status, 200, "{body}");
        body["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| {
                (
                    item["itemKey"].as_str().unwrap().to_owned(),
                    item["minBuyout"].as_i64().unwrap(),
                    item["marketValue"].as_i64().unwrap(),
                    item["marketScannedAt"].clone(),
                )
            })
            .collect()
    }
    assert_eq!(
        market(&f).await,
        [
            ("15477:584".to_owned(), 650, 600, json!(1793950000)),
            ("2589".to_owned(), 95, 110, json!(1793950000)),
        ]
    );

    let (poller, _blizzard) = battlenet_poller(&f).await;
    let poller = poll(poller).await;
    assert_eq!(
        market(&f).await,
        [
            ("15477:584".to_owned(), 650, 600, json!(1793950000)),
            ("15477".to_owned(), 500, 500, json!(1793956642)),
            ("2589".to_owned(), 95, 101, json!(1793956642)),
            ("4537".to_owned(), 45, 50, json!(1793956642)),
        ]
    );
    stop(poller).await;
}

#[tokio::test]
async fn an_upload_cannot_pass_for_a_battlenet_snapshot_while_polling() {
    let f = Fixture::new().await;
    let mut claimed = scan();
    claimed["realm"] = json!("EU PvP");
    claimed["scanner"] = json!("Battle.net");
    claimed["scannedAt"] = json!(4102444800_u64);
    let (status, _, body) = call(&f.app, "POST", "/api/scans", claimed.clone(), &f.auth()).await;
    assert_eq!(
        (status, body),
        (200, json!({"stored":true,"items":2})),
        "polling is off, so uploads are as before"
    );

    let mut config = battlenet(f.database());
    config.auctions = AuctionConfig::parse("1", "client", "secret").unwrap();
    let polling = router(config).unwrap();
    claimed["scannedAt"] = json!(4102444801_u64);
    let (status, _, body) = call(&polling, "POST", "/api/scans", claimed, &f.auth()).await;
    assert_eq!(
        (status, body),
        (400, json!({"error":"scanner Battle.net is reserved"}))
    );

    let (poller, _blizzard) = battlenet_poller(&f).await;
    let poller = poll(poller).await;
    let (_, _, body) = call(
        &f.app,
        "GET",
        "/api/history?realm=EU%20PvP&faction=Horde&itemKey=4537",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(
        body["points"].as_array().map(|points| points
            .iter()
            .map(|point| point["scannedAt"].clone())
            .collect::<Vec<_>>()),
        Some(vec![json!(1793956642)]),
        "the future-dated upload does not hold the poller back: {body}"
    );
    stop(poller).await;
}

#[tokio::test]
async fn a_players_newer_scan_keeps_its_prices_over_an_older_snapshot() {
    let f = Fixture::new().await;
    upload(
        &f,
        forever_scan(
            "CAMWOWEU4Realm8PvP",
            1793960000,
            "browse",
            json!([["2589", 95, 0, 7, 0]]),
            json!({"2589":["Linen Cloth",1]}),
        ),
    )
    .await;
    let (poller, _blizzard) = battlenet_poller(&f).await;
    let poller = poll(poller).await;

    let export = horde_export(&f).await;
    assert_eq!(export["scannedAt"], 1793960000);
    assert_eq!(
        export["items"],
        json!({
            "2589":{"name":"Linen Cloth","quality":1,"price":[95,7,0,1793960000,101,1793956642],"hours":[[498321,100,4,101],[498322,95,7,0]],"days":[[20763,95,7,101]]},
            "4537":{"name":null,"quality":null,"price":[45,125,3,1793956642,50,1793956642],"hours":[[498321,45,125,50]],"days":[[20763,45,125,50]]},
            "15477":{"name":null,"quality":null,"price":[500,1,1,1793956642,500,1793956642],"hours":[[498321,500,1,500]],"days":[[20763,500,1,500]]}
        })
    );
    let (_, _, prices) = call(
        &f.app,
        "GET",
        "/api/prices?realm=CAMWOWEU4Realm8PvP&faction=Horde",
        Value::Null,
        &[],
    )
    .await;
    let mut prices = listed(&prices);
    prices.sort();
    assert_eq!(
        prices,
        [
            ("15477".to_owned(), 500, 1793956642),
            ("2589".to_owned(), 95, 1793960000),
            ("4537".to_owned(), 45, 1793956642),
        ]
    );
    stop(poller).await;
}

// What the website's Order book panel reads for an item of the EU PvP Horde
// house: the shown book's time, its levels as [unit price, units, cumulative
// units, cumulative cost], and the time of every book in its history. Null
// when the item has no book.
async fn horde_book(f: &Fixture, item: &str) -> Value {
    let (status, _, body) = call(
        &f.app,
        "GET",
        &format!("/api/sellers?realm=CAMWOWEU4Realm8PvP&faction=Horde&itemKey={item}&history=1"),
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(status, 200, "{body}");
    let Some(levels) = body["snapshot"]["orderBook"].as_array() else {
        return body["snapshot"].clone();
    };
    json!({
        "scannedAt": body["snapshot"]["scannedAt"],
        "orderBook": levels
            .iter()
            .map(|level| json!([level["unitPrice"], level["quantity"], level["cumulativeQuantity"], level["cumulativeCost"]]))
            .collect::<Vec<_>>(),
        "history": body["history"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["scannedAt"].clone())
            .collect::<Vec<_>>(),
    })
}

#[tokio::test]
async fn battlenet_snapshots_replace_their_items_order_books_and_keep_players() {
    let f = Fixture::new().await;
    // The fake serves only house 113, so this stands in for a book that a
    // poll of the Alliance house stored.
    db::connect(&f.database()).unwrap().execute_batch(r#"INSERT INTO seller_snapshots (fingerprint,realm,faction,item_key,scanned_at,payload,house) VALUES ('alliance','EU PvP','Alliance','4537',1793950000,'{"realm":"EU PvP","faction":"Alliance","itemKey":"4537","scannedAt":1793950000,"offers":[{"unitPrice":60,"quantity":1,"owners":[],"totalOwners":0}]}','EU PvP')"#).unwrap();
    let (poller, blizzard) = battlenet_poller(&f).await;
    let poller = poll(poller).await;
    assert_eq!(
        horde_book(&f, "4537").await,
        json!({"scannedAt":1793956642,"orderBook":[[45,5,5,225],[50,20,25,1225],[80,100,125,9225]],"history":[1793956642]})
    );
    assert_eq!(
        horde_book(&f, "2589").await,
        json!({"scannedAt":1793956642,"orderBook":[[100,1,1,100],[101,1,2,201],[120,1,3,321],[400,1,4,721]],"history":[1793956642]})
    );
    assert_eq!(
        horde_book(&f, "15477").await,
        json!({"scannedAt":1793956642,"orderBook":[[500,1,1,500]],"history":[1793956642]}),
        "the listing with bonus_lists is not in the book"
    );
    assert_eq!(
        horde_book(&f, "9999").await,
        Value::Null,
        "a bid without a buyout is no book"
    );

    blizzard.lock().unwrap().snapshot = second_snapshot();
    let poller = poll(poller).await;
    assert_eq!(
        horde_book(&f, "4537").await,
        json!({"scannedAt":1793960242,"orderBook":[[44,10,10,440]],"history":[1793960242]})
    );
    assert_eq!(
        horde_book(&f, "15477").await,
        json!({"scannedAt":1793956642,"orderBook":[[500,1,1,500]],"history":[1793956642]}),
        "an item gone from the snapshot keeps its last book"
    );

    let book = json!({"realm":"CAMWOWEU4Realm8PvP","faction":"Horde","itemKey":"4537","scannedAt":1793961000,
        "offers":[{"unitPrice":43,"quantity":2,"owners":["Feretuse"],"totalOwners":1}]});
    assert_eq!(
        call(&f.app, "POST", "/api/sellers", book, &f.auth())
            .await
            .2,
        json!({"stored":true})
    );
    assert_eq!(
        horde_book(&f, "4537").await,
        json!({"scannedAt":1793961000,"orderBook":[[43,2,2,86]],"history":[1793961000,1793960242]})
    );

    blizzard.lock().unwrap().snapshot = Snapshot {
        modified: "Fri, 6 Nov 2026 11:17:22 GMT",
        since: "Fri, 06 Nov 2026 11:17:22 GMT",
        ..second_snapshot()
    };
    let poller = poll(poller).await;
    assert_eq!(
        horde_book(&f, "4537").await,
        json!({"scannedAt":1793963842,"orderBook":[[44,10,10,440]],"history":[1793963842,1793961000]}),
        "the player's book stays"
    );
    let (_, _, alliance) = call(
        &f.app,
        "GET",
        "/api/sellers?realm=CAMWOWEU4Realm8PvP&faction=Alliance&itemKey=4537",
        Value::Null,
        &[],
    )
    .await;
    assert_eq!(
        alliance["snapshot"]["orderBook"],
        json!([{"unitPrice":60,"quantity":1,"cumulativeQuantity":1,"cumulativeCost":60,"owners":[],"hasUnnamedOwners":true}]),
        "the other faction's polled book stays"
    );
    stop(poller).await;
}

#[tokio::test]
async fn books_stored_before_a_failed_scan_are_not_stored_twice() {
    let f = Fixture::new().await;
    let db = db::connect(&f.database()).unwrap();
    db.execute_batch("CREATE TRIGGER reject_scan BEFORE INSERT ON scans BEGIN SELECT RAISE(ABORT,'test failure'); END;").unwrap();
    let (poller, _blizzard) = battlenet_poller(&f).await;
    let poller = poll(poller).await;
    assert_eq!(stored_scans(&f).await, json!([]));
    let book = json!({"scannedAt":1793956642,"orderBook":[[45,5,5,225],[50,20,25,1225],[80,100,125,9225]],"history":[1793956642]});
    assert_eq!(horde_book(&f, "4537").await, book);

    db.execute_batch("DROP TRIGGER reject_scan").unwrap();
    let poller = poll(poller).await;
    assert_eq!(
        stored_scans(&f).await,
        json!([{"realm":"EU PvP","faction":"Horde","region":"EU","scans":1,"lastScan":1793956642}])
    );
    assert_eq!(horde_book(&f, "4537").await, book);
    stop(poller).await;
}

#[tokio::test]
async fn battlenet_names_the_items_no_player_named() {
    let f = Fixture::new().await;
    let (poller, blizzard) = battlenet_poller(&f).await;
    blizzard.lock().unwrap().items = vec![
        (FOREVER, 2589, "Linen Cloth", "COMMON"),
        (CLASSIC_ERA, 2589, "Linen Cloth", "POOR"),
        (FOREVER, 15477, "Bandit Cinch", "WOW_TOKEN"),
        (CLASSIC_ERA, 15477, "Bandit Cinch", "UNCOMMON"),
    ];
    let poller = poll(poller).await;
    assert_eq!(
        horde_names(&f).await,
        json!({
            "2589":["Linen Cloth",1,"battlenet-forever"],
            "4537":[null,null,null],
            "15477":["Bandit Cinch",2,"battlenet-classic-era"]
        })
    );
    assert_eq!(
        blizzard.lock().unwrap().looked_up,
        [
            (FOREVER, 15477),
            (CLASSIC_ERA, 15477),
            (FOREVER, 2589),
            (FOREVER, 4537),
            (CLASSIC_ERA, 4537),
        ]
    );

    blizzard
        .lock()
        .unwrap()
        .items
        .push((CLASSIC_ERA, 4537, "Tel'Abim Banana", "COMMON"));
    let poller = poll(poller).await;
    assert_eq!(
        horde_names(&f).await,
        json!({
            "2589":["Linen Cloth",1,"battlenet-forever"],
            "4537":["Tel'Abim Banana",1,"battlenet-classic-era"],
            "15477":["Bandit Cinch",2,"battlenet-classic-era"]
        })
    );
    assert_eq!(
        blizzard.lock().unwrap().looked_up[5..],
        [(FOREVER, 4537), (CLASSIC_ERA, 4537)],
        "an item no namespace knew is asked of both again on the next pass"
    );
    stop(poller).await;
}

#[tokio::test]
async fn a_players_item_names_win_over_battlenets() {
    let f = Fixture::new().await;
    upload(
        &f,
        forever_scan(
            "CAMWOWEU4Realm8PvP",
            1793950000,
            "browse",
            json!([["2589", 95, 0, 7, 0], ["15477:584", 650, 0, 1, 0]]),
            json!({"2589":["Linen Cloth",1]}),
        ),
    )
    .await;
    upload(
        &f,
        forever_scan(
            "Faramon",
            1793950000,
            "browse",
            json!([["7070", 300, 0, 5, 0]]),
            json!({}),
        ),
    )
    .await;
    let (poller, blizzard) = battlenet_poller(&f).await;
    blizzard.lock().unwrap().items = vec![
        (FOREVER, 2589, "Linen Cloth", "POOR"),
        (FOREVER, 4537, "Tel'Abim Banana", "COMMON"),
        // Classic Era rates 15477 a quality lower than the players' clients do.
        (CLASSIC_ERA, 15477, "Bandit Cinch", "COMMON"),
    ];
    let poller = poll(poller).await;
    assert_eq!(
        horde_names(&f).await,
        json!({
            "2589":["Linen Cloth",1,"player"],
            "4537":["Tel'Abim Banana",1,"battlenet-forever"],
            "15477":["Bandit Cinch",1,"battlenet-classic-era"],
            "15477:584":[null,null,null]
        })
    );
    let requested = [(FOREVER, 15477), (CLASSIC_ERA, 15477), (FOREVER, 4537)];
    assert_eq!(blizzard.lock().unwrap().looked_up, requested);

    // 15477 as the addon uploads a name it imported from ServerData.lua.
    upload(
        &f,
        forever_scan(
            "CAMWOWEU4Realm8PvP",
            1793960000,
            "browse",
            json!([["4537", 44, 0, 10, 0], ["15477", 480, 0, 1, 0]]),
            json!({"4537":["Tel'Abim-Banane",1],"15477":["Bandit Cinch",1]}),
        ),
    )
    .await;
    blizzard
        .lock()
        .unwrap()
        .items
        .push((FOREVER, 15477, "Bandit Cinch", "UNCOMMON"));
    let poller = poll(poller).await;
    assert_eq!(
        horde_names(&f).await,
        json!({
            "2589":["Linen Cloth",1,"player"],
            "4537":["Tel'Abim-Banane",1,"player"],
            "15477":["Bandit Cinch",1,"battlenet-classic-era"],
            "15477:584":[null,null,null]
        }),
        "Forever knowing 15477 later does not replace Classic Era's name"
    );
    assert_eq!(
        blizzard.lock().unwrap().looked_up,
        requested,
        "named items are not looked up again"
    );

    upload(
        &f,
        forever_scan(
            "CAMWOWEU4Realm8PvP",
            1793963600,
            "browse",
            json!([["15477", 470, 0, 1, 0]]),
            json!({"15477":["Bandit Cinch",2]}),
        ),
    )
    .await;
    assert_eq!(
        horde_names(&f).await["15477"],
        json!(["Bandit Cinch", 2, "player"]),
        "a player's quality replaces Classic Era's"
    );
    stop(poller).await;
}

#[tokio::test]
async fn a_failed_lookup_ends_the_pass_and_the_next_pass_goes_on() {
    let f = Fixture::new().await;
    let (poller, blizzard) = battlenet_poller(&f).await;
    {
        let mut blizzard = blizzard.lock().unwrap();
        blizzard.items = vec![
            (FOREVER, 15477, "Bandit Cinch", "UNCOMMON"),
            (FOREVER, 4537, "Tel'Abim Banana", "COMMON"),
            (CLASSIC_ERA, 2589, "Linen Cloth", "COMMON"),
            (CLASSIC_ERA, 4537, "Tel'Abim Banana", "COMMON"),
        ];
        blizzard.failing = Some((CLASSIC_ERA, 2589));
    }
    let poller = poll(poller).await;
    assert_eq!(
        horde_names(&f).await,
        json!({
            "2589":[null,null,null],
            "4537":[null,null,null],
            "15477":["Bandit Cinch",2,"battlenet-forever"]
        })
    );
    assert_eq!(
        blizzard.lock().unwrap().looked_up,
        [(FOREVER, 15477), (FOREVER, 2589), (CLASSIC_ERA, 2589)]
    );

    blizzard.lock().unwrap().failing = Some((FOREVER, 4537));
    let poller = poll(poller).await;
    assert_eq!(
        horde_names(&f).await,
        json!({
            "2589":["Linen Cloth",1,"battlenet-classic-era"],
            "4537":[null,null,null],
            "15477":["Bandit Cinch",2,"battlenet-forever"]
        })
    );
    assert_eq!(
        blizzard.lock().unwrap().looked_up[3..],
        [(FOREVER, 2589), (CLASSIC_ERA, 2589), (FOREVER, 4537)],
        "a failed Forever request ends the pass instead of asking Classic Era"
    );
    stop(poller).await;
}

#[tokio::test]
async fn a_name_a_player_stores_during_the_lookup_stays() {
    let f = Fixture::new().await;
    let (poller, blizzard) = battlenet_poller(&f).await;
    let database = f.database();
    {
        let mut blizzard = blizzard.lock().unwrap();
        blizzard.items = vec![(FOREVER, 4537, "Tel'Abim Banana", "COMMON")];
        // An upload's name for 4537 lands after the pass chose to look it up.
        blizzard.meanwhile = Some(Box::new(move || {
            db::connect(&database).unwrap().execute("INSERT INTO items (item_key,name,quality,source) VALUES ('4537','Tel''Abim-Banane',1,'player')", []).unwrap();
        }));
    }
    let poller = poll(poller).await;
    assert_eq!(
        horde_names(&f).await["4537"],
        json!(["Tel'Abim-Banane", 1, "player"])
    );
    assert_eq!(
        blizzard.lock().unwrap().looked_up,
        [
            (FOREVER, 15477),
            (CLASSIC_ERA, 15477),
            (FOREVER, 2589),
            (CLASSIC_ERA, 2589),
            (FOREVER, 4537),
        ]
    );
    stop(poller).await;
}

#[tokio::test]
async fn naming_stops_at_its_budget_and_the_next_pass_goes_on() {
    let f = Fixture::new().await;
    let known = vec![
        (FOREVER, 2589, "Linen Cloth", "COMMON"),
        (FOREVER, 4537, "Tel'Abim Banana", "COMMON"),
    ];
    let (poller, blizzard) = battlenet_poller_with(&f, |config| {
        config.naming_budget = std::time::Duration::ZERO;
    })
    .await;
    blizzard.lock().unwrap().items = known.clone();
    let poller = poll(poller).await;
    let unnamed = json!({
        "2589":[null,null,null],
        "4537":[null,null,null],
        "15477":[null,null,null]
    });
    assert_eq!(horde_names(&f).await, unnamed);
    assert_eq!(
        blizzard.lock().unwrap().looked_up,
        Vec::<(&str, u64)>::new()
    );
    stop(poller).await;

    let (poller, blizzard) = battlenet_poller(&f).await;
    blizzard.lock().unwrap().items = known;
    let poller = poll(poller).await;
    assert_eq!(
        horde_names(&f).await,
        json!({
            "2589":["Linen Cloth",1,"battlenet-forever"],
            "4537":["Tel'Abim Banana",1,"battlenet-forever"],
            "15477":[null,null,null]
        })
    );
    stop(poller).await;
}
