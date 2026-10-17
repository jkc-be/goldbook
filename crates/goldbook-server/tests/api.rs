use axum::{
    Router,
    body::{Body, to_bytes},
    extract::ConnectInfo,
    http::{HeaderMap, Request},
};
use goldbook_server::{Config, db, router};
use serde_json::{Value, json};
use std::{
    net::SocketAddr,
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};
use tower::ServiceExt;

struct Fixture {
    directory: PathBuf,
    app: Router,
}
impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let directory = std::env::temp_dir().join(format!(
            "goldbook-server-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let app = router(Config::new(
            directory.join("goldbook.sqlite"),
            "dev-token,friend-token",
        ))
        .unwrap();
        Self { directory, app }
    }
    fn database(&self) -> PathBuf {
        self.directory.join("goldbook.sqlite")
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
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
const AUTH: [(&str, &str); 1] = [("authorization", "Bearer dev-token")];
#[tokio::test]
async fn scans_preserve_identity_late_names_market_borrowing_and_queries() {
    let f = Fixture::new();
    let mut first = scan();
    first["items"] = json!({});
    assert_eq!(
        call(&f.app, "POST", "/api/scans", first, &AUTH).await.2,
        json!({"stored":true,"items":2})
    );
    let mut retry = scan();
    retry["rows"].as_array_mut().unwrap().reverse();
    assert_eq!(
        call(&f.app, "POST", "/api/scans", retry, &AUTH).await.2,
        json!({"stored":false,"items":2})
    );
    let mut quick = scan();
    quick["mode"] = json!("browse");
    quick["rows"] = json!([["2589", 100, 0, 10, 0]]);
    assert_eq!(
        call(
            &f.app,
            "POST",
            "/api/scans",
            quick,
            &[("authorization", "Bearer friend-token")]
        )
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
    let f = Fixture::new();
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
            json!([["2589", 110, 125, 42, 3], ["4306:1024", 500, 520, 3, 1]]),
            json!({"2589": ["Linen Cloth", 1]}),
        ),
        (
            "Faramon",
            "Horde",
            1760086900,
            "browse",
            json!([["2589", 100, 0, 10, 0], ["4306:1024", 480, 0, 2, 0]]),
            json!({}),
        ),
        (
            "Faramon",
            "Horde",
            1760090000,
            "replicate",
            json!([["2589", 100, 105, 100, 4]]),
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
        assert_eq!(call(&f.app, "POST", "/api/scans", scan, &AUTH).await.0, 200);
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
                    "price": [100, 100, 4, 1760090000, 105, 1760090000],
                    "hours": [[488746, 115, 20, 118], [488912, 110, 42, 125], [488913, 100, 10, 105]],
                    "days": [[20311, 120, 30, 0], [20364, 115, 20, 118], [20371, 100, 10, 105]]
                },
                "4306:1024": {
                    "name": null,
                    "quality": null,
                    "price": [480, 2, 0, 1760086900, 520, 1760083260],
                    "hours": [[488912, 500, 3, 520], [488913, 480, 2, 0]],
                    "days": [[20371, 480, 2, 520]]
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
#[tokio::test]
async fn account_ownership_rotation_and_sessions_remain_atomic() {
    let f = Fixture::new();
    assert_eq!(
        call(&f.app, "POST", "/api/account", account(), &AUTH)
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
        call(&f.app, "POST", "/api/account", rotated.clone(), &AUTH)
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
        call(&f.app, "POST", "/api/account", rotated, &AUTH).await.0,
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
    let f = Fixture::new();
    call(&f.app, "POST", "/api/scans", scan(), &AUTH).await;
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
        call(&f.app, "POST", "/api/account", upload.clone(), &AUTH)
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
        json!({"name":"Mirelle","realm":"Faramon","at":1760000200,"side":"buy","item":"Linen Cloth","itemKey":"2589","quality":1,"count":20,"price":1500,"fee":0}),
        "newest first, with the quality of a known item"
    );
    assert_eq!(first[3]["quality"], Value::Null);
    call(&f.app, "POST", "/api/account", upload.clone(), &AUTH).await;
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
    call(&f.app, "POST", "/api/account", upload.clone(), &AUTH).await;
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
    let (status, _, error) = call(&f.app, "POST", "/api/account", upload, &AUTH).await;
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
    call(&f.app, "POST", "/api/account", other, &AUTH).await;
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
    let f = Fixture::new();
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
        call(&f.app, "POST", "/api/account", upload.clone(), &AUTH)
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
    let (status, _, error) = call(&f.app, "POST", "/api/account", upload, &AUTH).await;
    assert_eq!(
        (status, error["error"].clone()),
        (
            400,
            json!("trades[0].fee must not exceed the price, and only an auction sale has one")
        )
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
    let f = Fixture::new();
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
    call(&f.app, "POST", "/api/account", mac, &AUTH).await;
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
    call(&f.app, "POST", "/api/account", fedora.clone(), &AUTH).await;
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
    call(&f.app, "POST", "/api/account", fedora, &AUTH).await;
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
    call(&f.app, "POST", "/api/account", third, &AUTH).await;
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
    let f = Fixture::new();
    let mut other = account();
    other["keyHash"] = json!(goldbook_core::key_hash("ABCDEFGHJKMNPQRSTVWX"));
    let (a, b) = tokio::join!(
        call(&f.app, "POST", "/api/account", account(), &AUTH),
        call(&f.app, "POST", "/api/account", other, &AUTH)
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
    let f = Fixture::new();
    call(&f.app, "POST", "/api/account", account(), &AUTH).await;
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
    let f = Fixture::new();
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
        raw(&f.app, "POST", "/api/scans", b"{bad json".to_vec(), &AUTH)
            .await
            .0,
        400
    );
    assert_eq!(raw(&f.app, "POST", "/api/scans", vec![], &[]).await.0, 401);
}
#[tokio::test]
async fn upgrading_a_python_database_preserves_ids_prices_and_retry_identity() {
    let f = Fixture::new();
    // Recreate the schema immediately before Python's fingerprint migration.
    let mut db = db::connect(&f.database()).unwrap();
    db.execute_batch("DROP TABLE prices; DROP TABLE scans; DELETE FROM migrations WHERE name='0005_scan_fingerprints.sql';").unwrap();
    db.execute_batch("CREATE TABLE scans (id INTEGER PRIMARY KEY,realm TEXT NOT NULL,faction TEXT NOT NULL,region TEXT NOT NULL,scanned_at INTEGER NOT NULL,mode TEXT NOT NULL,scanner TEXT NOT NULL,build TEXT NOT NULL,item_count INTEGER NOT NULL,uploaded_at INTEGER NOT NULL,UNIQUE(realm,faction,scanned_at)); CREATE TABLE prices(scan_id INTEGER NOT NULL REFERENCES scans(id),item_key TEXT NOT NULL,min_buyout INTEGER NOT NULL,market_value INTEGER NOT NULL,quantity INTEGER NOT NULL,num_auctions INTEGER NOT NULL,PRIMARY KEY(scan_id,item_key)) WITHOUT ROWID;").unwrap();
    db.execute_batch("INSERT INTO scans VALUES (7,'Faramon','Horde','EU',1760000000,'replicate','Sultan','1.60.1.70338',2,1760000010); INSERT INTO prices VALUES (7,'2589',110,125,42,3),(7,'7070',300,320,5,2);").unwrap();
    db::migrate(&mut db).unwrap();
    let app = router(Config::new(f.database(), "dev-token")).unwrap();
    assert_eq!(
        call(&app, "POST", "/api/scans", scan(), &AUTH).await.2,
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
async fn json_surrogates_validate_at_original_length_then_match_python_storage() {
    let f = Fixture::new();
    let body = serde_json::to_string(&scan())
        .unwrap()
        .replace("\"Faramon\"", &format!("\"{}\\ud800\"", "a".repeat(63)));
    let (status, _, response) = raw(
        &f.app,
        "POST",
        "/api/scans",
        body.as_bytes().to_vec(),
        &AUTH,
    )
    .await;
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&response));
    assert_eq!(
        raw(
            &f.app,
            "POST",
            "/api/scans",
            body.as_bytes().to_vec(),
            &AUTH
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
    let f = Fixture::new();
    let web = f.directory.join("web");
    std::fs::create_dir(&web).unwrap();
    std::fs::write(web.join("index.html"), b"custom index").unwrap();
    let mut config = Config::new(f.database(), "dev-token");
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
    let f = Fixture::new();
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
    let f = Fixture::new();
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
    let fixture = Fixture::new();
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
    let f = Fixture::new();
    let mut config = Config::new(f.database(), "");
    config.self_registration = true;
    let app = router(config).unwrap();
    let (status, headers, body) =
        call(&app, "POST", "/api/installations", registration("a"), &[]).await;
    assert_eq!(status, 200);
    assert_eq!(headers["cache-control"], "no-store");
    let token = body["token"].as_str().unwrap();
    assert!(token.starts_with("gb_"));
    assert_eq!(token.len(), 46);
    let authorization = format!("Bearer {token}");
    let auth = [("authorization", authorization.as_str())];
    let db = db::connect(&f.database()).unwrap();
    let stored: String = db
        .query_row("SELECT token_hash FROM upload_tokens", [], |row| row.get(0))
        .unwrap();
    use sha2::{Digest, Sha256};
    assert_eq!(stored, hex::encode(Sha256::digest(token.as_bytes())));
    assert_ne!(stored, token);
    assert_eq!(call(&app, "POST", "/api/scans", scan(), &auth).await.0, 200);
    assert_eq!(
        call(&app, "POST", "/api/account", account(), &auth).await.0,
        200
    );
    let mut other = account();
    other["keyHash"] = json!(goldbook_core::key_hash("OTHERKEYABCDEFGHJKMN"));
    assert_eq!(
        call(&app, "POST", "/api/account", other, &auth).await.0,
        409
    );
    assert_eq!(
        call(
            &app,
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
        call(&app, "GET", "/api/account", Value::Null, &auth)
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
    ] {
        assert_eq!(
            call(&app, "POST", "/api/scans", scan(), headers).await.0,
            401
        );
    }
    // Existing credentials survive a restart and disabling new issuance.
    let restarted = router(Config::new(f.database(), "")).unwrap();
    assert_eq!(
        call(
            &restarted,
            "POST",
            "/api/installations",
            registration("a"),
            &[]
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
    assert_eq!(call(&app, "POST", "/api/scans", scan(), &auth).await.0, 401);
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
async fn registration_is_opt_in_validates_bodies_and_limits_issuance() {
    let f = Fixture::new();
    assert_eq!(
        call(&f.app, "POST", "/api/installations", registration("a"), &[])
            .await
            .0,
        403
    );
    // Administrator-provisioned tokens continue to work.
    assert_eq!(
        call(&f.app, "POST", "/api/scans", scan(), &AUTH).await.0,
        200
    );
    let mut config = Config::new(f.database(), "dev-token");
    config.self_registration = true;
    let app = router(config).unwrap();
    for body in [json!(null), json!([]), json!({"token":"provided"})] {
        assert_eq!(
            call(&app, "POST", "/api/installations", body, &[]).await.0,
            400
        );
    }
    assert_eq!(
        raw(
            &app,
            "POST",
            "/api/installations",
            b"{".to_vec(),
            &[("content-type", "application/json")]
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
            &[("content-type", "text/plain")]
        )
        .await
        .0,
        415
    );
    assert_eq!(
        raw(&app, "POST", "/api/installations", b"{}".to_vec(), &[])
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
            &[("content-type", "application/json")]
        )
        .await
        .0,
        413
    );
    // Invalid JSON consumes attempts too: four previous handler calls plus sixteen successes.
    for _ in 0..16 {
        assert_eq!(
            call(&app, "POST", "/api/installations", registration("a"), &[])
                .await
                .0,
            200
        );
    }
    assert_eq!(
        call(&app, "POST", "/api/installations", registration("a"), &[])
            .await
            .0,
        429
    );
    let count: i64 = db::connect(&f.database())
        .unwrap()
        .query_row("SELECT count(*) FROM upload_tokens", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 16);
    // Registration limits are independent from login failures.
    assert_eq!(
        call(&app, "POST", "/api/login", json!({}), &[]).await.0,
        401
    );
    assert_eq!(call(&app, "POST", "/api/scans", scan(), &AUTH).await.0, 200);
}

#[tokio::test]
async fn fingerprint_blocks_cover_every_credential_and_future_registrations() {
    let f = Fixture::new();
    let mut config = Config::new(f.database(), "dev-token");
    config.self_registration = true;
    let app = router(config).unwrap();
    let mut tokens = Vec::new();
    for digit in ["a", "a", "b"] {
        let reply = call(&app, "POST", "/api/installations", registration(digit), &[]).await;
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
    let issuance = tokio::spawn(async move {
        call(
            &issuing_app,
            "POST",
            "/api/installations",
            registration("a"),
            &[],
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
    assert_eq!(call(&app, "POST", "/api/scans", scan(), &AUTH).await.0, 200);
    let count: i64 = db
        .query_row("SELECT count(*) FROM upload_tokens", [], |row| row.get(0))
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
        call(&app, "POST", "/api/installations", registration("a"), &[])
            .await
            .0,
        200
    );
}

#[tokio::test]
async fn registration_requires_only_versioned_lowercase_account_fingerprints() {
    let f = Fixture::new();
    let mut config = Config::new(f.database(), "");
    config.self_registration = true;
    let app = router(config).unwrap();
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
            call(&app, "POST", "/api/installations", invalid, &[])
                .await
                .0,
            400
        );
    }
    let db = db::connect(&f.database()).unwrap();
    let count: i64 = db
        .query_row("SELECT count(*) FROM upload_identities", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(count, 0);
    assert_eq!(
        call(&app, "POST", "/api/installations", registration("f"), &[])
            .await
            .0,
        200
    );
}

#[tokio::test]
async fn seller_batches_require_auth_validate_atomically_and_deduplicate() {
    let f = Fixture::new();
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
        call(&f.app, "POST", "/api/sellers/batch", invalid, &AUTH)
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
        call(&f.app, "POST", "/api/sellers/batch", batch.clone(), &AUTH)
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
        call(&f.app, "POST", "/api/sellers/batch", batch.clone(), &AUTH)
            .await
            .2,
        json!({"stored":2,"received":2})
    );
    assert_eq!(
        call(&f.app, "POST", "/api/sellers/batch", batch.clone(), &AUTH)
            .await
            .2,
        json!({"stored":0,"received":2})
    );
    assert_eq!(
        call(&f.app, "POST", "/api/sellers", batch[0].clone(), &AUTH)
            .await
            .2,
        json!({"stored":false})
    );
    for body in [json!([]), json!(vec![batch[0].clone(); 101])] {
        assert_eq!(
            call(&f.app, "POST", "/api/sellers/batch", body, &AUTH)
                .await
                .0,
            400
        );
    }
}
