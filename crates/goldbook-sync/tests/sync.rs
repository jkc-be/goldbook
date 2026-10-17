use axum::{extract::State, routing::post, Json, Router};
use goldbook_sync::*;
use serde_json::{json, Value};
use std::{
    path::Path,
    sync::{Arc, Mutex},
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
    assert!(serde_json::to_string(&a)
        .unwrap()
        .find("7KQ2M9PXABCDEFGHJKMN")
        .is_none());
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
    assert!(std::fs::read_to_string(targets[0].join("Goldbook.toc"))
        .unwrap()
        .contains("https://example/goldbook"));
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
    assert!(!std::fs::read_dir(dir.path()).unwrap().any(|p| p
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with(".tmp")));
    task.abort();
}
#[tokio::test]
async fn state_remembers_old_account_payloads_and_rotates_key_with_previous_hash() {
    let (api, received, task) = server().await;
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("account.lua");
    let state = dir.path().join("state.json");
    let text="GoldbookDB={[\"account\"]={[\"id\"]=\"K7Q2M9PX\",[\"key\"]=\"7KQ2M9PXABCDEFGHJKMN\"},[\"items\"]={},[\"scans\"]={}}";
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
            if line.starts_with("watching ") {
                if let Some(tx) = ready.lock().unwrap().take() {
                    let _ = tx.send(());
                }
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
