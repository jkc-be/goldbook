use crate::settings::{self, DEFAULT_API, Settings, normalize_api};
use anyhow::{Result, bail};
use goldbook_sync::{WatchFile, account_fingerprint, saved_variables_files};
use serde::Deserialize;
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    time::Duration,
};

pub fn needs_registration(settings: &Settings) -> bool {
    settings.token.trim().is_empty()
        || (settings.token.trim() == "dev-token"
            && normalize_api(&settings.api).is_ok_and(|api| api == DEFAULT_API))
}

pub struct UploadSetup {
    pub known_files: Vec<PathBuf>,
    pub files: Vec<WatchFile>,
    pub blocked: usize,
}

#[derive(Deserialize)]
struct Registration {
    token: String,
}

async fn register(api: &str, fingerprint: &str, session: Option<&str>) -> Result<Option<String>> {
    let client = goldbook_sync::api_client(api, Duration::from_secs(10))?;
    let request = client
        .post(goldbook_sync::api_url(api, "/api/installations")?)
        .header("content-type", "application/json")
        .body(serde_json::json!({"fingerprint":fingerprint,"fingerprintVersion":1}).to_string());
    let request = match session {
        Some(session) => request.bearer_auth(session),
        None => request,
    };
    let mut response = request.send().await.map_err(|_| {
        anyhow::anyhow!(
            "Goldbook cannot reach that server to set up uploads. Try again when you are connected."
        )
    })?;
    let status = response.status().as_u16();
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| {
        anyhow::anyhow!("Goldbook could not finish upload setup. Try again when you are connected.")
    })? {
        if body.len() + chunk.len() > 4096 {
            bail!("The server returned an invalid upload setup response.");
        }
        body.extend_from_slice(&chunk);
    }
    match status {
        200..=299 => {}
        401 => bail!("Log in with Battle.net in Goldbook to set up uploads."),
        403 if serde_json::from_slice::<serde_json::Value>(&body)
            .ok()
            .is_some_and(|v| v["error"] == "this account is blocked") =>
        {
            return Ok(None);
        }
        403 | 404 => bail!(
            "This server does not support automatic upload setup. Ask its administrator to enable automatic setup or update the server, or enter an upload token in Settings."
        ),
        429 => bail!(
            "This server has received too many setup requests. Wait 15 minutes, then try again."
        ),
        code => bail!(
            "The server answered {code} during upload setup. Try again later, or enter an upload token in Settings."
        ),
    }
    let registration: Registration = serde_json::from_slice(&body)
        .map_err(|_| anyhow::anyhow!("The server returned an invalid upload setup response."))?;
    let valid = registration
        .token
        .strip_prefix("gb_")
        .is_some_and(|secret| {
            secret.len() == 43
                && secret
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        });
    if !valid {
        bail!("The server returned an invalid upload setup response.");
    }
    Ok(Some(registration.token))
}

pub async fn prepare_uploads(settings: &mut Settings, config: &Path) -> Result<UploadSetup> {
    let known_files = saved_variables_files(Some(Path::new(&settings.wow_dir)));
    let mut files = Vec::new();
    let mut blocked = HashSet::new();
    if !needs_registration(settings) {
        for file in &known_files {
            files.push(WatchFile {
                file: file.clone(),
                token: settings.token.clone(),
            });
        }
    } else {
        if settings.battlenet_session.is_none() && !known_files.is_empty() {
            match crate::battlenet::enabled(&settings.api).await {
                Ok(true) => bail!("Log in with Battle.net in Goldbook to set up uploads."),
                Ok(false) => {}
                Err(error) => {
                    let all_cached = known_files.iter().all(|file| {
                        account_fingerprint(file).is_ok_and(|fingerprint| {
                            settings.upload_tokens.contains_key(&fingerprint)
                        })
                    });
                    if !all_cached {
                        return Err(error);
                    }
                }
            }
        }
        settings.token.clear();
        for file in &known_files {
            let fingerprint = account_fingerprint(file)?;
            if blocked.contains(&fingerprint) {
                continue;
            }
            if !settings.upload_tokens.contains_key(&fingerprint) {
                match register(
                    &settings.api,
                    &fingerprint,
                    settings.battlenet_session.as_deref(),
                )
                .await?
                {
                    Some(token) => {
                        settings.upload_tokens.insert(fingerprint.clone(), token);
                        // Persist each credential before another account can fail setup.
                        settings::write(config, settings)?;
                    }
                    None => {
                        blocked.insert(fingerprint);
                        continue;
                    }
                }
            }
            files.push(WatchFile {
                file: file.clone(),
                token: settings.upload_tokens[&fingerprint].clone(),
            });
        }
    }
    settings::write(config, settings)?;
    Ok(UploadSetup {
        known_files,
        files,
        blocked: blocked.len(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::Router;
    use goldbook_server::{Config, router};

    fn account_files(root: &Path, account: &str) {
        for flavor in ["_retail_", "_classic_"] {
            std::fs::create_dir_all(
                root.join(flavor)
                    .join("WTF/Account")
                    .join(account)
                    .join("SavedVariables"),
            )
            .unwrap();
        }
    }

    #[test]
    fn only_empty_tokens_and_the_official_legacy_default_register() {
        let mut settings = Settings::default();
        assert!(needs_registration(&settings));
        settings.token = "dev-token".into();
        settings.api = format!("{DEFAULT_API}/");
        assert!(needs_registration(&settings));
        settings.api = "https://custom.example/goldbook".into();
        assert!(!needs_registration(&settings));
        settings.token.clear();
        assert!(needs_registration(&settings));
        for token in ["manual-token", "gb_revoked"] {
            settings.token = token.into();
            assert!(!needs_registration(&settings));
        }
    }

    #[tokio::test]
    async fn oauth_gates_cached_anonymous_tokens_and_sends_enrollment_session() {
        use axum::{
            Json,
            routing::{get, post},
        };
        let temp = tempfile::tempdir().unwrap();
        account_files(temp.path(), "ACCOUNT");
        let app = Router::new()
            .route("/goldbook/api/auth/battlenet/status", get(|| async { Json(serde_json::json!({"enabled":true})) }))
            .route("/goldbook/api/installations", post(|headers: axum::http::HeaderMap, Json(body): Json<serde_json::Value>| async move {
                assert_eq!(headers["authorization"], "Bearer enrollment-session");
                assert_eq!(body.as_object().unwrap().len(), 2);
                assert_eq!(body["fingerprintVersion"], 1);
                assert_eq!(body["fingerprint"].as_str().unwrap().len(), 64);
                Json(serde_json::json!({"token":format!("gb_{}", "a".repeat(43))}))
            }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let api = format!("http://{}/goldbook", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let mut settings = Settings {
            api,
            wow_dir: temp.path().to_string_lossy().into(),
            ..Settings::default()
        };
        let fingerprint = account_fingerprint(
            &temp
                .path()
                .join("_retail_/WTF/Account/ACCOUNT/SavedVariables/Goldbook.lua"),
        )
        .unwrap();
        settings
            .upload_tokens
            .insert(fingerprint, "old-anonymous-token".into());
        let config = temp.path().join("settings.json");
        assert!(
            prepare_uploads(&mut settings, &config)
                .await
                .err()
                .unwrap()
                .to_string()
                .contains("Log in with Battle.net in Goldbook")
        );
        settings.upload_tokens.clear();
        settings.battlenet_session = Some("enrollment-session".into());
        let setup = prepare_uploads(&mut settings, &config).await.unwrap();
        assert_eq!(setup.files.len(), 2);
        assert_eq!(settings.upload_tokens.len(), 1);
        server.abort();
    }

    #[tokio::test]
    async fn real_server_keeps_accounts_separate_and_reuses_saved_credentials() {
        let temp = tempfile::tempdir().unwrap();
        let game = temp.path().join("game");
        account_files(&game, "ACCOUNT_A");
        account_files(&game, "ACCOUNT_B");
        let database = temp.path().join("server.sqlite");
        let mut config = Config::new(&database, "");
        config.self_registration = true;
        let app = Router::new().nest("/goldbook", router(config).unwrap());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let api = format!("http://{}/goldbook", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            axum::serve(
                listener,
                app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await
            .unwrap();
        });
        let file = temp.path().join("settings.json");
        let mut settings = Settings {
            api: api.clone(),
            wow_dir: game.to_string_lossy().into(),
            ..Settings::default()
        };
        let setup = prepare_uploads(&mut settings, &file).await.unwrap();
        assert_eq!(setup.known_files.len(), 4);
        assert_eq!(setup.files.len(), 4);
        assert_eq!(settings.upload_tokens.len(), 2);
        let db = goldbook_server::db::connect(&database).unwrap();
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM upload_tokens", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            2
        );
        let mut loaded = settings::read(&file);
        prepare_uploads(&mut loaded, &file).await.unwrap();
        assert_eq!(loaded.upload_tokens, settings.upload_tokens);
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM upload_tokens", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            2
        );
        let client = reqwest::Client::new();
        for source in &setup.files {
            let fingerprint = account_fingerprint(&source.file).unwrap();
            assert_eq!(source.token, loaded.upload_tokens[&fingerprint]);
            let response = client
                .post(format!("{api}/api/scans"))
                .bearer_auth(&source.token)
                .header("content-type", "application/json")
                .body("{}")
                .send()
                .await
                .unwrap();
            assert_eq!(response.status().as_u16(), 400);
        }
        let blocked = account_fingerprint(
            &game.join("_retail_/WTF/Account/ACCOUNT_A/SavedVariables/Goldbook.lua"),
        )
        .unwrap();
        db.execute(
            "UPDATE upload_identities SET blocked_at=unixepoch() WHERE fingerprint=?1",
            [&blocked],
        )
        .unwrap();
        // A reset client cannot obtain new credentials for the blocked account.
        let mut reset = Settings {
            api: api.clone(),
            wow_dir: game.to_string_lossy().into(),
            ..Settings::default()
        };
        let next = prepare_uploads(&mut reset, &file).await.unwrap();
        assert_eq!(next.blocked, 1);
        assert_eq!(next.files.len(), 2);
        assert_eq!(reset.upload_tokens.len(), 1);
        assert!(!reset.upload_tokens.contains_key(&blocked));
        let response = client
            .post(format!("{api}/api/scans"))
            .bearer_auth(&loaded.upload_tokens[&blocked])
            .header("content-type", "application/json")
            .body("{}")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), 403);
        // A saved credential needs no setup request when offline.
        server.abort();
        prepare_uploads(&mut loaded, &file).await.unwrap();
        assert_eq!(loaded.upload_tokens, settings.upload_tokens);
    }

    #[tokio::test]
    async fn manual_token_and_missing_account_folders_need_no_registration() {
        let temp = tempfile::tempdir().unwrap();
        let game = temp.path().join("game");
        account_files(&game, "ACCOUNT");
        let mut settings = Settings {
            api: "http://127.0.0.1:1".into(),
            wow_dir: game.to_string_lossy().into(),
            token: "manual-token".into(),
            ..Settings::default()
        };
        let setup = prepare_uploads(&mut settings, &temp.path().join("settings.json"))
            .await
            .unwrap();
        assert_eq!(setup.files.len(), 2);
        assert!(setup.files.iter().all(|s| s.token == "manual-token"));
        settings.token.clear();
        settings.wow_dir = temp.path().join("empty").to_string_lossy().into();
        let setup = prepare_uploads(&mut settings, &temp.path().join("settings.json"))
            .await
            .unwrap();
        assert!(setup.files.is_empty());
        assert!(settings.upload_tokens.is_empty());
    }
}
