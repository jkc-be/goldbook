use axum::{Json, Router, extract::State, routing::post};
use goldbook_sync::*;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
const FIXTURE: &[u8] = include_bytes!("data/Goldbook.lua");
fn logger() -> Logger {
    Arc::new(|_| {})
}
#[test]
fn account_fingerprint_uses_only_the_ascii_uppercase_account_name() {
    let expected = "bf01cfe6cb9fae92a730204d1a1fcb4d11538c34e4af5d75a32dfdeab5f12648";
    for file in [
        "/Applications/World of Warcraft/_retail_/WTF/Account/12345678#1/SavedVariables/Goldbook.lua",
        "/other/root/_classic_/wtf/account/12345678#1/savedvariables/goldbook.LUA",
    ] {
        assert_eq!(account_fingerprint(Path::new(file)).unwrap(), expected);
    }
    let lower = Path::new("/one/_retail_/WTF/Account/Example#1/SavedVariables/Goldbook.lua");
    let upper = Path::new("/two/_classic_/WTF/Account/EXAMPLE#1/SavedVariables/Goldbook.lua");
    assert_eq!(
        account_fingerprint(lower).unwrap(),
        account_fingerprint(upper).unwrap()
    );
    assert_eq!(
        account_fingerprint(Path::new(
            "/root/_retail_/WTF/Account/12345678#2/SavedVariables/Goldbook.lua"
        ))
        .unwrap(),
        "30ccdd5903e0e96e54b9053a5521b0fcea3ac5eea24547d4cf348ca1fcc7a22b"
    );
    for invalid in [
        "/root/_retail_/WTF/Account/12345678#1/Goldbook.lua",
        "/root/_retail_/WTF/Other/12345678#1/SavedVariables/Goldbook.lua",
        "/root/retail/WTF/Account/12345678#1/SavedVariables/Goldbook.lua",
        "/root/_retail_/WTF/Account/12345678#1/SavedVariables/Other.lua",
    ] {
        assert!(
            account_fingerprint(Path::new(invalid)).is_err(),
            "{invalid}"
        );
    }
}

#[cfg(unix)]
#[test]
fn account_fingerprint_rejects_non_utf8_account_names() {
    use std::os::unix::ffi::OsStrExt;
    let file = Path::new("/root/_retail_/WTF/Account")
        .join(std::ffi::OsStr::from_bytes(b"invalid\xff"))
        .join("SavedVariables/Goldbook.lua");
    assert!(account_fingerprint(&file).is_err());
}
#[test]
fn safe_byte_parser_supports_utf8_escapes_and_nonfinite_literals() {
    let parsed=parse_saved_variables("S = \"Ünï\\n\\065\\\\\"\nA={inf,-inf,1.#INF,-1.#INF,nan,-nan(ind),-1.#IND,1.#QNAN}\nB={[\"next\"]=2}").unwrap();
    assert_eq!(parsed["S"], json!("Ünï\nA\\"));
    assert_eq!(parsed["A"].as_array().unwrap().len(), 8);
    assert!(parsed["A"][0].is_object());
    assert_eq!(parsed["B"]["next"], 2);
    assert!(parse_saved_variables("A = os.execute('bad')").is_err());
    assert_eq!(
        parse_saved_variables("A = {\n[\"k\"] = \"cut off")
            .unwrap_err()
            .to_string(),
        "unterminated string at byte 22"
    );
}
#[test]
fn addon_fixture_decodes_prices_names_and_queue_identity() {
    let mut saved = parse_saved_variables(FIXTURE).unwrap();
    let scans = extract_scans(&saved).unwrap();
    assert_eq!(scans.len(), 3);
    let scan = scans[2].decode().unwrap();
    assert_eq!(scan.rows[0], ("2589".into(), 100, 105, 100, 4));
    assert_eq!(
        scan.items["9775:584"],
        ("Bandit Cinch of the Monkey".into(), 2)
    );
    assert_eq!(
        scans[0].decode().unwrap().items["2592"].0,
        "Thrall's \"Ünicode\" Wool, Fine"
    );
    let original_id = scans[0].id.clone();
    saved["GoldbookDB"]["items"]["2592"] = json!("1|new name");
    assert_eq!(extract_scans(&saved).unwrap()[0].id, original_id);
    saved["GoldbookDB"]["scans"][0]["count"] = json!(0);
    assert_eq!(extract_scans(&saved).unwrap()[0].id, original_id);
    assert!(extract_scans(&saved).unwrap()[0].decode().is_err());
    saved["GoldbookDB"]["scans"][1]["at"] = saved["GoldbookDB"]["scans"][0]["at"].clone();
    let scans = extract_scans(&saved).unwrap();
    assert_ne!(scans[0].id, scans[1].id);
}
#[test]
fn account_extraction_sorts_gold_and_uses_only_valid_login_keys() {
    let saved=parse_saved_variables("GoldbookDB={[\"account\"]={[\"id\"]=\"K7Q2M9PX\",[\"key\"]=\"7KQ2M9PXABCDEFGHJKMN\"},[\"gold\"]={[\"Sultan-Faramon\"]={[497759]=5000,[497735]=1234}},[\"items\"]={},[\"scans\"]={}}").unwrap();
    let a = extract_account(&saved).unwrap().unwrap();
    assert_eq!(
        a.characters[0].gold,
        vec![(1791846000, 1234), (1791932400, 5000)]
    );
    assert_eq!(a.characters[0].name, "Sultan");
    assert!(
        serde_json::to_string(&a)
            .unwrap()
            .find("7KQ2M9PXABCDEFGHJKMN")
            .is_none()
    );
    let mut broken = saved;
    broken["GoldbookDB"]["account"]["key"] = json!("short");
    assert!(extract_account(&broken).is_err());
}
#[test]
fn account_extraction_carries_valid_trades_and_leaves_them_out_when_there_are_none() {
    let plain = "GoldbookDB={[\"account\"]={[\"id\"]=\"K7Q2M9PX\",[\"key\"]=\"7KQ2M9PXABCDEFGHJKMN\"},[\"gold\"]={[\"Sultan-Faramon\"]={[497759]=5000}},[\"items\"]={},[\"scans\"]={}";
    let before = extract_account(&parse_saved_variables(format!("{plain}}}")).unwrap())
        .unwrap()
        .unwrap();
    let empty =
        extract_account(&parse_saved_variables(format!("{plain},[\"trades\"]={{}}}}")).unwrap())
            .unwrap()
            .unwrap();
    assert_eq!(
        serde_json::to_string(&empty).unwrap(),
        serde_json::to_string(&before).unwrap(),
        "an account without trades uploads as it did before trades existed"
    );
    assert!(!serde_json::to_string(&before).unwrap().contains("trades"));
    let sale = "{[\"at\"]=1760000100,[\"side\"]=\"sell\",[\"item\"]=\"Linen Cloth\",[\"key\"]=\"2589\",[\"count\"]=20,[\"price\"]=2000,[\"fee\"]=100}";
    let buy = "{[\"at\"]=1760000000,[\"side\"]=\"buy\",[\"item\"]=\"Gnomish Widget\",[\"count\"]=1,[\"price\"]=700,[\"fee\"]=0}";
    let broken = "{[\"at\"]=1760000000,[\"side\"]=\"gift\",[\"item\"]=\"Linen Cloth\",[\"count\"]=1,[\"price\"]=1,[\"fee\"]=0}";
    let text = format!(
        "{plain},[\"trades\"]={{[\"Sultan-Fara mon\"]={{{sale},{sale},{broken}}},[\"Mirelle-Faramon\"]={{{buy}}},[\"nameless\"]={{{buy}}}}}}}"
    );
    let account = extract_account(&parse_saved_variables(text).unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(
        serde_json::to_value(&account.trades).unwrap(),
        json!([
            {"name":"Mirelle","realm":"Faramon","at":1760000000,"side":"buy","item":"Gnomish Widget","itemKey":null,"count":1,"price":700,"fee":0},
            {"name":"Sultan","realm":"Faramon","at":1760000100,"side":"sell","item":"Linen Cloth","itemKey":"2589","count":20,"price":2000,"fee":100},
            {"name":"Sultan","realm":"Faramon","at":1760000100,"side":"sell","item":"Linen Cloth","itemKey":"2589","count":20,"price":2000,"fee":100}
        ]),
        "equal trades both travel, the realm is normalized, and a trade the server would refuse or without a character is left out"
    );
}
#[test]
fn addon_fixture_carries_accounting_entries_with_their_party() {
    let account = extract_account(&parse_saved_variables(FIXTURE).unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(
        serde_json::to_value(&account.trades).unwrap(),
        json!([
            {"name":"Mirelle","realm":"Faramon","at":1760000300,"side":"tradeBuy","item":"Linen Cloth","itemKey":"2589","count":20,"price":0,"fee":0,"party":"Sultan"},
            {"name":"Mirelle","realm":"Faramon","at":1760000350,"side":"tradeOut","item":"Gold","itemKey":null,"count":1,"price":50000,"fee":0,"party":"Sultan"},
            {"name":"Sultan","realm":"Faramon","at":1759996800,"side":"loot","item":"Looted gold","itemKey":null,"count":37,"price":8120,"fee":0},
            {"name":"Sultan","realm":"Faramon","at":1760000300,"side":"tradeSell","item":"Linen Cloth","itemKey":"2589","count":20,"price":0,"fee":0,"party":"Mirelle"},
            {"name":"Sultan","realm":"Faramon","at":1760000350,"side":"tradeIn","item":"Gold","itemKey":null,"count":1,"price":50000,"fee":0,"party":"Mirelle"},
            {"name":"Sultan","realm":"Faramon","at":1760000400,"side":"mailIn","item":"Thanks for the help","itemKey":null,"count":1,"price":12000,"fee":0,"party":"Mirelle"},
            {"name":"Sultan","realm":"Faramon","at":1760000500,"side":"repair","item":"Repairs","itemKey":null,"count":1,"price":3456,"fee":0}
        ]),
        "a party travels when booked, a missing fee is no cut, and gold mailed for nothing is left out"
    );
    let mut saved = parse_saved_variables(FIXTURE).unwrap();
    saved["GoldbookDB"]["trades"]["Sultan-Faramon"][1]["side"] = json!("sell");
    let sales = extract_account(&saved).unwrap().unwrap().trades;
    assert_eq!(
        sales.iter().filter(|t| t.price == 50000).count(),
        1,
        "an auction sale without its fee is left out"
    );
}
#[test]
fn urls_and_install_preserve_subpath_and_original_addon() {
    assert_eq!(
        api_url("https://app.example/goldbook", "/api/scans")
            .unwrap()
            .as_str(),
        "https://app.example/goldbook/api/scans"
    );
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source");
    std::fs::create_dir(&source).unwrap();
    std::fs::write(source.join("Goldbook.toc"), "## X-Website: old\nCode.lua\n").unwrap();
    std::fs::create_dir_all(dir.path().join("_classic_/Interface/AddOns")).unwrap();
    let targets =
        install_addon(Some(dir.path()), &source, Some("https://example/goldbook")).unwrap();
    assert_eq!(targets.len(), 1);
    assert!(
        std::fs::read_to_string(targets[0].join("Goldbook.toc"))
            .unwrap()
            .contains("https://example/goldbook")
    );
    assert_eq!(
        std::fs::read_to_string(source.join("Goldbook.toc")).unwrap(),
        "## X-Website: old\nCode.lua\n"
    );
}
#[test]
fn linux_discovery_finds_proton_and_prefers_installed_flavors() {
    let home = tempfile::tempdir().unwrap();
    let plain = home
        .path()
        .join(".wine/drive_c/Program Files (x86)/World of Warcraft");
    std::fs::create_dir_all(&plain).unwrap();
    let proton=home.path().join(".local/share/Steam/steamapps/compatdata/123/pfx/drive_c/Program Files (x86)/World of Warcraft");
    std::fs::create_dir_all(proton.join("_classic_")).unwrap();
    assert_eq!(
        pick_wow_dir(&linux_wow_candidates(home.path())).unwrap(),
        proton
    );
}
async fn server() -> (String, Arc<Mutex<Vec<Value>>>, tokio::task::JoinHandle<()>) {
    let received = Arc::new(Mutex::new(Vec::new()));
    let app = Router::new()
        .route(
            "/goldbook/api/scans",
            post(
                |State(rows): State<Arc<Mutex<Vec<Value>>>>, Json(body): Json<Value>| async move {
                    rows.lock().unwrap().push(body);
                    "ok"
                },
            ),
        )
        .route(
            "/goldbook/api/account",
            post(
                |State(rows): State<Arc<Mutex<Vec<Value>>>>, Json(body): Json<Value>| async move {
                    rows.lock().unwrap().push(body);
                    "ok"
                },
            ),
        )
        .with_state(received.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (format!("http://{address}/goldbook"), received, task)
}
fn options(file: &Path, state: &Path, api: &str) -> SyncOptions {
    SyncOptions {
        file: file.into(),
        state_path: state.into(),
        api: api.into(),
        token: "test".into(),
        log: logger(),
    }
}
#[tokio::test]
async fn concurrent_passes_do_not_duplicate_scans_and_state_merges_files() {
    let (api, received, task) = server().await;
    let dir = tempfile::tempdir().unwrap();
    let one = dir.path().join("one.lua");
    let two = dir.path().join("two.lua");
    let scans_only = String::from_utf8(FIXTURE.into()).unwrap().replace(
        "[\"account\"] = {\n[\"id\"] = \"K7Q2M9PX\",\n[\"key\"] = \"7KQ2M9PXABCDEFGHJKMN\",\n},\n",
        "",
    );
    assert!(!scans_only.contains("[\"account\"]"));
    std::fs::write(&one, &scans_only).unwrap();
    let mut changed = scans_only;
    changed = changed.replace("Faramon", "OtherRealm");
    std::fs::write(&two, changed).unwrap();
    let state = dir.path().join("state.json");
    let a = options(&one, &state, &api);
    let b = options(&two, &state, &api);
    let (r1, r2, r3) = tokio::join!(sync_file(&a), sync_file(&a), sync_file(&b));
    assert_eq!(r1.unwrap().sent, 3);
    assert_eq!(r2.unwrap().already_sent, 3);
    assert_eq!(r3.unwrap().sent, 3);
    assert_eq!(received.lock().unwrap().len(), 6);
    let saved: Value = serde_json::from_slice(&std::fs::read(&state).unwrap()).unwrap();
    assert_eq!(saved["uploaded"].as_array().unwrap().len(), 6);
    assert_eq!(sync_file(&a).await.unwrap().already_sent, 3);
    assert!(
        !std::fs::read_dir(dir.path()).unwrap().any(|p| p
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".tmp"))
    );
    task.abort();
}
#[tokio::test]
async fn state_remembers_old_account_payloads_and_rotates_key_with_previous_hash() {
    let (api, received, task) = server().await;
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("account.lua");
    let state = dir.path().join("state.json");
    let text = "GoldbookDB={[\"account\"]={[\"id\"]=\"K7Q2M9PX\",[\"key\"]=\"7KQ2M9PXABCDEFGHJKMN\"},[\"items\"]={},[\"scans\"]={}}";
    std::fs::write(&file, text).unwrap();
    let options = options(&file, &state, &api);
    assert_eq!(sync_file(&options).await.unwrap().sent, 1);
    assert_eq!(sync_file(&options).await.unwrap().already_sent, 1);
    std::fs::write(
        &file,
        text.replace("7KQ2M9PXABCDEFGHJKMN", "ABCDEFGHJKMNPQRSTVWX"),
    )
    .unwrap();
    assert_eq!(sync_file(&options).await.unwrap().sent, 1);
    assert_eq!(
        received.lock().unwrap()[1]["previousKeyHash"],
        "1f2a4b22637651b9c0e4169e248acbe887d2e3d0ea98321f1bf1452f9b6ecb79"
    );
    let mut legacy: Value = serde_json::from_slice(&std::fs::read(&state).unwrap()).unwrap();
    legacy["accounts"]["K7Q2M9PX"] = legacy["accounts"]["K7Q2M9PX"]["payload"].clone();
    std::fs::write(&state, serde_json::to_vec(&legacy).unwrap()).unwrap();
    assert_eq!(sync_file(&options).await.unwrap().already_sent, 1);
    task.abort();
}
#[tokio::test]
async fn watcher_reads_files_replaced_by_rename() {
    let (api, received, task) = server().await;
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("Goldbook.lua");
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
    let ready = Arc::new(Mutex::new(Some(ready_tx)));
    let handle = watch_files(WatchOptions {
        interval: Some(Duration::from_secs(15)),
        files: vec![WatchFile {
            file: file.clone(),
            token: "test".into(),
        }],
        api,
        state_path: dir.path().join("state.json"),
        log: Arc::new(move |line| {
            if line.starts_with("watching ")
                && let Some(tx) = ready.lock().unwrap().take()
            {
                let _ = tx.send(());
            }
        }),
    })
    .unwrap();
    tokio::time::timeout(Duration::from_secs(5), ready_rx)
        .await
        .unwrap()
        .unwrap();
    let unfinished = dir.path().join("Goldbook.lua.tmp");
    std::fs::write(&unfinished, FIXTURE).unwrap();
    std::fs::rename(unfinished, &file).unwrap();
    tokio::time::timeout(Duration::from_secs(7), async {
        loop {
            if received.lock().unwrap().len() == 4 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await
        }
    })
    .await
    .unwrap();
    handle.close();
    task.abort();
}

#[tokio::test]
async fn watcher_routes_each_accounts_upload_with_its_own_credential() {
    type ReceivedUploads = Arc<Mutex<Vec<(String, String)>>>;
    let received = Arc::new(Mutex::new(Vec::<(String, String)>::new()));
    let app = Router::new()
        .route(
            "/goldbook/api/account",
            post(
                |State(received): State<ReceivedUploads>,
                 headers: axum::http::HeaderMap,
                 Json(body): Json<Value>| async move {
                    let id = body["id"].as_str().unwrap().to_owned();
                    let bearer = headers
                        .get("authorization")
                        .unwrap()
                        .to_str()
                        .unwrap()
                        .to_owned();
                    let expected = match id.as_str() {
                        "K7Q2M9PX" => "Bearer account-one-token",
                        "K7Q2M9PY" => "Bearer account-two-token",
                        _ => return axum::http::StatusCode::UNAUTHORIZED,
                    };
                    if bearer != expected {
                        return axum::http::StatusCode::UNAUTHORIZED;
                    }
                    received.lock().unwrap().push((id, bearer));
                    axum::http::StatusCode::OK
                },
            ),
        )
        .with_state(received.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let directory = tempfile::tempdir().unwrap();
    let mut files = Vec::new();
    for (account, id, token) in [
        ("12345678#1", "K7Q2M9PX", "account-one-token"),
        ("12345678#2", "K7Q2M9PY", "account-two-token"),
    ] {
        let file = directory
            .path()
            .join("_retail_/WTF/Account")
            .join(account)
            .join("SavedVariables/Goldbook.lua");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, format!("GoldbookDB={{[\"account\"]={{[\"id\"]=\"{id}\",[\"key\"]=\"7KQ2M9PXABCDEFGHJKMN\"}},[\"gold\"]={{[\"Sultan-Faramon\"]={{[497759]=5000}}}},[\"items\"]={{}},[\"scans\"]={{}}}}")).unwrap();
        files.push(WatchFile {
            file,
            token: token.into(),
        });
    }
    let handle = watch_files(WatchOptions {
        files,
        api: format!("http://{address}/goldbook"),
        state_path: directory.path().join("state.json"),
        interval: None,
        log: logger(),
    })
    .unwrap();
    let results = handle.sync_now().await.unwrap();
    assert_eq!(
        results
            .iter()
            .map(|result| (result.sent, result.failed))
            .collect::<Vec<_>>(),
        vec![(1, 0), (1, 0)]
    );
    assert_eq!(
        *received.lock().unwrap(),
        vec![
            ("K7Q2M9PX".to_owned(), "Bearer account-one-token".to_owned()),
            ("K7Q2M9PY".to_owned(), "Bearer account-two-token".to_owned()),
        ]
    );
    handle.close();
    server.abort();
}

#[tokio::test]
async fn watcher_without_interval_uploads_only_on_sync_now() {
    let (api, received, task) = server().await;
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("Goldbook.lua");
    std::fs::write(&file, FIXTURE).unwrap();
    let handle = watch_files(WatchOptions {
        interval: None,
        files: vec![WatchFile {
            file,
            token: "test".into(),
        }],
        api,
        state_path: dir.path().join("state.json"),
        log: Arc::new(|_| {}),
    })
    .unwrap();
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!(received.lock().unwrap().len(), 0);
    let results = handle.sync_now().await.unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(received.lock().unwrap().len(), 4);
    handle.close();
    task.abort();
}

#[test]
fn display_realm_aliases_preserve_gold_newer_bags_and_older_bank() {
    let saved = parse_saved_variables(include_bytes!("data/RealmAliases.lua")).unwrap();
    let account = extract_account(&saved).unwrap().unwrap();
    assert_eq!(
        serde_json::to_value(account.characters).unwrap(),
        json!([{
            "name":"Faramon", "realm":"ClassicBetaPvP2", "faction":null, "class":"PALADIN", "level":24,
            "updatedAt":1791970261u64,
            "gold":[[1791846000u64,10000],[1791932400u64,116489],[1791936000u64,120000]],
            "bags":{"at":1791970261u64,"rows":[]}, "bank":{"at":1791930000u64,"rows":[]}
        }])
    );
}

#[test]
fn canonical_alias_wins_ties_and_merged_gold_keeps_latest_1500_hours() {
    let hours = (497735..499235)
        .map(|hour| (hour.to_string(), json!(hour)))
        .collect::<serde_json::Map<_, _>>();
    let input = json!({"GoldbookDB":{
        "account":{"id":"K7Q2M9PX","key":"7KQ2M9PXABCDEFGHJKMN"},
        "gold":{"Hero-Re alm":hours,"Hero-Realm":{"499234":42,"499235":99}},
        "characters":{
            "Hero-Realm":{"name":"Hero","realm":"Realm","at":1791970261u64,"level":24},
            "Hero-Re alm":{"name":"Hero","realm":"Re alm","at":1791970261u64,"level":23}
        }
    }});
    let account = extract_account(input.as_object().unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(account.characters.len(), 1);
    let character = &account.characters[0];
    assert_eq!(character.realm, "Realm");
    assert_eq!(character.level, Some(24));
    assert_eq!(character.gold.len(), 1500);
    assert_eq!(character.gold.first(), Some(&(497736 * 3600, 497736)));
    assert_eq!(
        &character.gold[1498..],
        &[(499234 * 3600, 42), (499235 * 3600, 99)]
    );
}

#[test]
fn addon_updates_replace_obsolete_files_recover_interrupted_swap_and_preserve_saved_variables() {
    use std::fs;
    let temp = tempfile::tempdir().unwrap();
    let flavor = temp.path().join("_classic_");
    let addons = flavor.join("Interface/AddOns");
    let source = temp.path().join("source");
    let saved = flavor.join("WTF/Account/TEST/SavedVariables/Goldbook.lua");
    fs::create_dir_all(saved.parent().unwrap()).unwrap();
    fs::write(&saved, "GoldbookDB = { keep = true }").unwrap();
    fs::create_dir_all(addons.join("Goldbook")).unwrap();
    fs::write(addons.join("Goldbook/Old.lua"), "obsolete").unwrap();
    fs::create_dir(&source).unwrap();
    fs::write(source.join("Goldbook.toc"), "## X-Website: old\nCore.lua\n").unwrap();
    fs::write(source.join("Core.lua"), "new code").unwrap();
    for _ in 0..2 {
        install_addon(Some(temp.path()), &source, Some("https://example/goldbook")).unwrap();
        assert_eq!(
            fs::read_to_string(addons.join("Goldbook/Core.lua")).unwrap(),
            "new code"
        );
        assert!(!addons.join("Goldbook/Old.lua").exists());
        assert_eq!(
            fs::read_to_string(&saved).unwrap(),
            "GoldbookDB = { keep = true }"
        );
    }
    fs::rename(addons.join("Goldbook"), addons.join(".Goldbook-backup")).unwrap();
    // Failed staging restores the addon that existed before an interrupted swap.
    assert!(install_addon(Some(temp.path()), &temp.path().join("missing"), None).is_err());
    assert_eq!(
        fs::read_to_string(addons.join("Goldbook/Core.lua")).unwrap(),
        "new code"
    );
    install_addon(Some(temp.path()), &source, None).unwrap();
    assert!(!addons.join(".Goldbook-backup").exists());
}
#[test]
fn addon_updates_keep_the_server_data_the_app_wrote() {
    use std::fs;
    let temp = tempfile::tempdir().unwrap();
    let addon = temp.path().join("_classic_/Interface/AddOns/Goldbook");
    let source = temp.path().join("source");
    fs::create_dir_all(&addon).unwrap();
    fs::create_dir(&source).unwrap();
    fs::write(source.join("Goldbook.toc"), "ServerData.lua\n").unwrap();
    fs::write(source.join("ServerData.lua"), "GoldbookServerData = nil\n").unwrap();
    install_addon(Some(temp.path()), &source, None).unwrap();
    assert_eq!(
        fs::read_to_string(addon.join("ServerData.lua")).unwrap(),
        "GoldbookServerData = nil\n"
    );
    let written = b"local data = { version = 1 }\nGoldbookServerData = data\n\xc3\xbc";
    fs::write(addon.join("ServerData.lua"), written).unwrap();
    for _ in 0..2 {
        fs::write(addon.join("Old.lua"), "obsolete").unwrap();
        install_addon(Some(temp.path()), &source, None).unwrap();
        assert_eq!(fs::read(addon.join("ServerData.lua")).unwrap(), written);
        assert!(!addon.join("Old.lua").exists());
        assert_eq!(
            fs::read_to_string(addon.join("Goldbook.toc")).unwrap(),
            "ServerData.lua\n"
        );
    }
}

#[tokio::test]
async fn seller_uploads_batch_retry_and_remember_more_than_500_snapshots() {
    let received = Arc::new(Mutex::new(Vec::<Value>::new()));
    let app = Router::new()
        .route(
            "/goldbook/api/sellers/batch",
            post(
                |State(rows): State<Arc<Mutex<Vec<Value>>>>, Json(body): Json<Value>| async move {
                    let mut rows = rows.lock().unwrap();
                    rows.push(body);
                    if rows.len() == 2 {
                        axum::http::StatusCode::SERVICE_UNAVAILABLE
                    } else {
                        axum::http::StatusCode::OK
                    }
                },
            ),
        )
        .with_state(received.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("Goldbook.lua");
    let mut saved = String::from(r#"GoldbookDB={["scans"]={},["items"]={},["sellerScans"]={"#);
    for i in 1..=601 {
        saved.push_str(&format!(r#"["{i}"]={{["realm"]="Faramon",["faction"]="Horde",["itemKey"]="{i}",["scannedAt"]=1760000000,["offers"]={{}}}},"#));
    }
    saved.push_str("}}");
    std::fs::write(&file, saved).unwrap();
    let options = options(
        &file,
        &dir.path().join("state.json"),
        &format!("http://{address}/goldbook"),
    );
    let first = sync_file(&options).await.unwrap();
    assert_eq!((first.sent, first.failed), (100, 100));
    let retry = sync_file(&options).await.unwrap();
    assert_eq!(
        (retry.sent, retry.already_sent, retry.failed),
        (501, 100, 0)
    );
    let again = sync_file(&options).await.unwrap();
    assert_eq!((again.sent, again.already_sent), (0, 601));
    let rows = received.lock().unwrap();
    assert_eq!(
        rows.iter()
            .map(|v| v.as_array().unwrap().len())
            .collect::<Vec<_>>(),
        vec![100, 100, 100, 100, 100, 100, 100, 1]
    );
    assert_eq!(rows[1], rows[2], "retry the unacknowledged batch");
    task.abort();
}
struct ExportMock {
    bodies: HashMap<String, Value>,
    fail: AtomicBool,
    requests: Mutex<Vec<(String, String, bool)>>,
}
async fn export_server(
    bodies: HashMap<String, Value>,
) -> (String, Arc<ExportMock>, tokio::task::JoinHandle<()>) {
    use axum::{extract::Query, http::StatusCode, response::IntoResponse, routing::get};
    let mock = Arc::new(ExportMock {
        bodies,
        fail: false.into(),
        requests: Mutex::new(Vec::new()),
    });
    let app = Router::new()
        .route(
            "/goldbook/api/export",
            get(
                |State(mock): State<Arc<ExportMock>>,
                 headers: axum::http::HeaderMap,
                 Query(query): Query<HashMap<String, String>>| async move {
                    let realm = query.get("realm").cloned().unwrap_or_default();
                    let faction = query.get("faction").cloned().unwrap_or_default();
                    mock.requests.lock().unwrap().push((
                        realm.clone(),
                        faction.clone(),
                        headers.contains_key("authorization"),
                    ));
                    if mock.fail.load(Ordering::SeqCst) {
                        return (StatusCode::INTERNAL_SERVER_ERROR, "database is down")
                            .into_response();
                    }
                    match mock.bodies.get(&format!("{realm}-{faction}")) {
                        // The mock serves only gzip, so a client that does not ask for it fails.
                        Some(body) => {
                            let asked = headers
                                .get("accept-encoding")
                                .and_then(|value| value.to_str().ok())
                                .is_some_and(|value| value.contains("gzip"));
                            if !asked {
                                return StatusCode::NOT_ACCEPTABLE.into_response();
                            }
                            let mut encoder = flate2::write::GzEncoder::new(
                                Vec::new(),
                                flate2::Compression::default(),
                            );
                            std::io::Write::write_all(&mut encoder, body.to_string().as_bytes())
                                .unwrap();
                            (
                                [
                                    ("content-type", "application/json"),
                                    ("content-encoding", "gzip"),
                                ],
                                encoder.finish().unwrap(),
                            )
                                .into_response()
                        }
                        None => (
                            StatusCode::NOT_FOUND,
                            Json(json!({"error":"no scans for this realm and faction"})),
                        )
                            .into_response(),
                    }
                },
            ),
        )
        .with_state(mock.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (format!("http://{address}/goldbook"), mock, task)
}
const STUB: &str = include_str!("../../../addon/Goldbook/ServerData.lua");
fn recording_logger() -> (Logger, Arc<Mutex<Vec<String>>>) {
    let lines = Arc::new(Mutex::new(Vec::new()));
    let sink = lines.clone();
    (
        Arc::new(move |line: &str| sink.lock().unwrap().push(line.to_owned())),
        lines,
    )
}
fn faramon_export() -> Value {
    json!({
        "realm": "Faramon",
        "faction": "Horde",
        "scannedAt": 1760090000,
        "items": {
            "2589": {
                "name": "Linen Cloth",
                "quality": 1,
                "price": [100, 100, 4, 1760090000, 105, 1760090000],
                "hours": [[488912, 110, 42, 0], [488913, 100, 100, 105]],
                "days": [[20371, 100, 100, 105]]
            },
            "2592": {
                "name": "Thrall's \"Ünicode\" Wool\\\n7",
                "quality": 1,
                "price": [250, 20, 0, 1760080000, 0, 0],
                "hours": [],
                "days": [[20371, 250, 20, 0]]
            }
        }
    })
}
fn write_account(flavor: &Path, account: &str, text: &str) -> std::path::PathBuf {
    let file = flavor
        .join("WTF/Account")
        .join(account)
        .join("SavedVariables/Goldbook.lua");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, text).unwrap();
    file
}
#[tokio::test]
async fn server_data_is_written_for_every_realm_in_the_flavor_and_kept_on_failure() {
    use std::fs;
    let (api, mock, task) = export_server(HashMap::from([
        ("Faramon-Horde".to_owned(), faramon_export()),
        (
            "PyrewoodVillage-Alliance".to_owned(),
            json!({
                "realm": "PyrewoodVillage",
                "faction": "Alliance",
                "scannedAt": 1760000000,
                "items": {
                    "9775:584": {
                        "name": null,
                        "quality": null,
                        "price": [5000, 1, 1, 1760000000, 4800, 1759990000],
                        "hours": [[488888, 5000, 1, 4800]],
                        "days": [[20370, 5000, 1, 4800]]
                    }
                }
            }),
        ),
    ]))
    .await;
    let temp = tempfile::tempdir().unwrap();
    let flavor = temp.path().join("_classic_");
    let addon = flavor.join("Interface/AddOns/Goldbook");
    fs::create_dir_all(&addon).unwrap();
    fs::write(addon.join("ServerData.lua"), STUB).unwrap();
    let one_text = "GoldbookDB = {\n[\"prices\"] = { [\"Faramon-Horde\"] = { [\"2589\"] = \"1,1,1,1,1,1;;\" } },\n[\"scanned\"] = { [\"Area 52-Alliance\"] = 1760000000 },\n}\n";
    let two_text = "GoldbookDB = {\n[\"characters\"] = { [\"Sultan-Pyrewood Village\"] = { [\"realm\"] = \"Pyrewood Village\", [\"faction\"] = \"Alliance\" } },\n[\"scanned\"] = { [\"Faramon-Horde\"] = 1760090000 },\n}\n";
    let one = write_account(&flavor, "ONE", one_text);
    let two = write_account(&flavor, "TWO", two_text);
    assert_eq!(flavor_of(&one), Some(flavor.clone()));
    assert_eq!(flavor_of(Path::new("/tmp/x.lua")), None);
    let (log, lines) = recording_logger();
    let path = addon.join("ServerData.lua");
    assert_eq!(
        write_server_data(&flavor, &api, &log).await.unwrap(),
        ServerData::Written {
            realms: vec!["Faramon-Horde".into(), "PyrewoodVillage-Alliance".into()],
            items: 3,
            path: path.clone(),
        }
    );
    let expected = format!(
        r#"-- The Goldbook app writes this file with prices from the Goldbook server.
-- The app rewrites it, so edits to it are lost.
local data = {{ version = 1, server = "{api}", items = {{}}, realms = {{}} }}
local function fill(t, f) f(t) end
fill(data.items, function(t)
t["2589"] = "1|Linen Cloth"
t["2592"] = "1|Thrall's \"Ünicode\" Wool\\\0107"
end)
data.realms["Faramon-Horde"] = {{ scannedAt = 1760090000, prices = {{}}, hours = {{}}, days = {{}} }}
fill(data.realms["Faramon-Horde"].prices, function(t)
t["2589"] = "100,100,4,1760090000,105,1760090000"
t["2592"] = "250,20,0,1760080000,0,0"
end)
fill(data.realms["Faramon-Horde"].hours, function(t)
t["2589"] = "488912:110:42:0,488913:100:100:105"
end)
fill(data.realms["Faramon-Horde"].days, function(t)
t["2589"] = "20371:100:100:105"
t["2592"] = "20371:250:20:0"
end)
data.realms["PyrewoodVillage-Alliance"] = {{ scannedAt = 1760000000, prices = {{}}, hours = {{}}, days = {{}} }}
fill(data.realms["PyrewoodVillage-Alliance"].prices, function(t)
t["9775:584"] = "5000,1,1,1760000000,4800,1759990000"
end)
fill(data.realms["PyrewoodVillage-Alliance"].hours, function(t)
t["9775:584"] = "488888:5000:1:4800"
end)
fill(data.realms["PyrewoodVillage-Alliance"].days, function(t)
t["9775:584"] = "20370:5000:1:4800"
end)
GoldbookServerData = data
"#
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), expected);
    assert_eq!(
        *mock.requests.lock().unwrap(),
        vec![
            ("Area 52".to_owned(), "Alliance".to_owned(), false),
            ("Faramon".to_owned(), "Horde".to_owned(), false),
            ("PyrewoodVillage".to_owned(), "Alliance".to_owned(), false),
        ]
    );
    let modified = fs::metadata(&path).unwrap().modified().unwrap();
    assert_eq!(
        write_server_data(&flavor, &api, &log).await.unwrap(),
        ServerData::Unchanged {
            realms: vec!["Faramon-Horde".into(), "PyrewoodVillage-Alliance".into()],
        }
    );
    assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), modified);
    mock.fail.store(true, Ordering::SeqCst);
    let error = write_server_data(&flavor, &api, &log).await.unwrap_err();
    assert_eq!(
        error.to_string(),
        "export of Area 52-Alliance answered 500 database is down"
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), expected);
    assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), modified);
    let shown = path.display();
    assert_eq!(
        *lines.lock().unwrap(),
        vec![
            format!(
                "server prices for Faramon-Horde, PyrewoodVillage-Alliance written to {shown}: 3 items"
            ),
            format!(
                "server prices for Faramon-Horde, PyrewoodVillage-Alliance unchanged in {shown}"
            ),
            format!(
                "server prices for {} failed: export of Area 52-Alliance answered 500 database is down",
                flavor.display()
            ),
        ]
    );
    let mut names = fs::read_dir(&addon)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    names.sort();
    assert_eq!(names, vec!["ServerData.lua"]);
    assert_eq!(fs::read_to_string(&one).unwrap(), one_text);
    assert_eq!(fs::read_to_string(&two).unwrap(), two_text);
    task.abort();
}
#[tokio::test]
async fn server_data_needs_the_addon_folder_and_a_realm_the_server_knows() {
    use std::fs;
    let (api, mock, task) = export_server(HashMap::new()).await;
    let temp = tempfile::tempdir().unwrap();
    let flavor = temp.path().join("_retail_");
    write_account(
        &flavor,
        "ONE",
        "GoldbookDB = { [\"scanned\"] = { [\"Area 52-Alliance\"] = 1 } }",
    );
    assert_eq!(
        write_server_data(&flavor, &api, &logger()).await.unwrap(),
        ServerData::NoAddon
    );
    assert_eq!(*mock.requests.lock().unwrap(), vec![]);
    let addon = flavor.join("Interface/AddOns/Goldbook");
    fs::create_dir_all(&addon).unwrap();
    fs::write(addon.join("ServerData.lua"), STUB).unwrap();
    assert_eq!(
        write_server_data(&flavor, &api, &logger()).await.unwrap(),
        ServerData::NoRealms
    );
    assert_eq!(
        *mock.requests.lock().unwrap(),
        vec![("Area 52".to_owned(), "Alliance".to_owned(), false)]
    );
    assert_eq!(
        fs::read_to_string(addon.join("ServerData.lua")).unwrap(),
        STUB
    );
    task.abort();
}
#[tokio::test]
async fn written_server_data_loads_in_luajit_beyond_its_constant_limit() {
    if std::process::Command::new("luajit")
        .arg("-v")
        .output()
        .is_err()
    {
        eprintln!("luajit is not on PATH, skipping");
        return;
    }
    let mut export = faramon_export();
    for i in 0..40_000 {
        export["items"][format!("{}", 100_000 + i)] = json!({
            "name": format!("Item {i}"),
            "quality": 2,
            "price": [i, 1, 1, 1760090000, 0, 0],
            "hours": [[488913, i, 1, 0]],
            "days": [[20371, i, 1, 0]]
        });
    }
    let (api, _mock, task) =
        export_server(HashMap::from([("Faramon-Horde".to_owned(), export)])).await;
    let temp = tempfile::tempdir().unwrap();
    let flavor = temp.path().join("_classic_era_");
    std::fs::create_dir_all(flavor.join("Interface/AddOns/Goldbook")).unwrap();
    write_account(
        &flavor,
        "ONE",
        "GoldbookDB = { [\"scanned\"] = { [\"Faramon-Horde\"] = 1 } }",
    );
    let ServerData::Written { path, items, .. } =
        write_server_data(&flavor, &api, &logger()).await.unwrap()
    else {
        panic!("server data was not written")
    };
    assert_eq!(items, 40_002);
    let check = r#"
dofile(os.getenv("SERVER_DATA"))
local data = GoldbookServerData
local realm = data.realms["Faramon-Horde"]
assert(data.version == 1)
assert(data.server == os.getenv("API"))
assert(realm.scannedAt == 1760090000)
assert(realm.prices["2589"] == "100,100,4,1760090000,105,1760090000")
assert(realm.hours["2589"] == "488912:110:42:0,488913:100:100:105")
assert(realm.days["2592"] == "20371:250:20:0")
assert(realm.hours["2592"] == nil)
assert(data.items["2592"] == "1|Thrall's \"\195\156nicode\" Wool\\\n7")
assert(data.items["124999"] == "2|Item 24999")
assert(realm.prices["124999"] == "24999,1,1,1760090000,0,0")
local count = 0
for _ in pairs(realm.prices) do count = count + 1 end
assert(count == 40002, count)
"#;
    let output = std::process::Command::new("luajit")
        .arg("-e")
        .arg(check)
        .env("SERVER_DATA", &path)
        .env("API", &api)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    task.abort();
}
#[tokio::test]
async fn watcher_refreshes_server_data_once_per_flavor_and_on_request() {
    let (api, mock, task) = export_server(HashMap::from([(
        "Faramon-Horde".to_owned(),
        faramon_export(),
    )]))
    .await;
    let temp = tempfile::tempdir().unwrap();
    let flavor = temp.path().join("_classic_");
    let addon = flavor.join("Interface/AddOns/Goldbook");
    std::fs::create_dir_all(&addon).unwrap();
    std::fs::write(addon.join("ServerData.lua"), STUB).unwrap();
    let text = "GoldbookDB = { [\"items\"] = {}, [\"scans\"] = {}, [\"scanned\"] = { [\"Faramon-Horde\"] = 1 } }";
    let files = ["ONE", "TWO"]
        .into_iter()
        .map(|account| WatchFile {
            file: write_account(&flavor, account, text),
            token: "test".into(),
        })
        .collect();
    let (log, lines) = recording_logger();
    let handle = watch_files(WatchOptions {
        files,
        api,
        state_path: temp.path().join("state.json"),
        interval: Some(Duration::from_secs(60)),
        log,
    })
    .unwrap();
    let path = addon.join("ServerData.lua");
    tokio::time::timeout(Duration::from_secs(5), async {
        while std::fs::read_to_string(&path).unwrap() == STUB {
            tokio::time::sleep(Duration::from_millis(50)).await
        }
    })
    .await
    .unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(
        *mock.requests.lock().unwrap(),
        vec![("Faramon".to_owned(), "Horde".to_owned(), false)]
    );
    let refreshed = handle.refresh_server_data().await;
    assert_eq!(refreshed.len(), 1);
    assert_eq!(refreshed[0].0, flavor);
    assert_eq!(
        refreshed[0].1.as_ref().unwrap(),
        &ServerData::Unchanged {
            realms: vec!["Faramon-Horde".into()]
        }
    );
    assert_eq!(mock.requests.lock().unwrap().len(), 2);
    let shown = path.display();
    assert_eq!(
        lines
            .lock()
            .unwrap()
            .iter()
            .filter(|line| line.starts_with("server prices "))
            .cloned()
            .collect::<Vec<_>>(),
        vec![
            format!("server prices for Faramon-Horde written to {shown}: 2 items"),
            format!("server prices for Faramon-Horde unchanged in {shown}"),
        ]
    );
    handle.close();
    task.abort();
}
#[tokio::test]
async fn watcher_downloads_server_data_at_most_every_15_minutes_unless_asked() {
    let (api, mock, task) = export_server(HashMap::from([(
        "Faramon-Horde".to_owned(),
        faramon_export(),
    )]))
    .await;
    let temp = tempfile::tempdir().unwrap();
    let flavor = temp.path().join("_classic_");
    let addon = flavor.join("Interface/AddOns/Goldbook");
    std::fs::create_dir_all(&addon).unwrap();
    let text = "GoldbookDB = { [\"items\"] = {}, [\"scans\"] = {}, [\"scanned\"] = { [\"Faramon-Horde\"] = 1 } }";
    let (log, lines) = recording_logger();
    let handle = watch_files(WatchOptions {
        files: vec![WatchFile {
            file: write_account(&flavor, "ONE", text),
            token: "test".into(),
        }],
        api,
        state_path: temp.path().join("state.json"),
        interval: Some(Duration::from_secs(1)),
        log,
    })
    .unwrap();
    tokio::time::sleep(Duration::from_millis(3500)).await;
    let passes = |lines: &Mutex<Vec<String>>| {
        lines
            .lock()
            .unwrap()
            .iter()
            .filter(|line| line.starts_with("server prices for Faramon-Horde"))
            .count()
    };
    assert_eq!(
        (mock.requests.lock().unwrap().len(), passes(&lines)),
        (1, 1),
        "four one-second sync passes download once"
    );
    handle.refresh_server_data().await;
    assert_eq!(
        (mock.requests.lock().unwrap().len(), passes(&lines)),
        (2, 2),
        "Sync now downloads again"
    );
    handle.close();
    task.abort();
}
