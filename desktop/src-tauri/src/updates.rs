use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD};
use minisign_verify::{PublicKey, Signature};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
    time::Duration,
};
use tauri::{Emitter, Manager};
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_updater::{Update, UpdaterExt};

const ROOT: &str = "https://app.jkc-be.com/goldbook/updates";
const MAX_ADDON: usize = 4 * 1024 * 1024;

#[derive(Clone, Serialize)]
#[serde(tag = "phase", rename_all = "camelCase")]
pub enum ClientStatus {
    Idle,
    Checking,
    Current,
    Downloading { version: String },
    Ready { version: String },
    Installing { version: String },
    Failed { message: String },
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub version: String,
    pub client: ClientStatus,
    pub addon: String,
}
pub struct Updates {
    pub status: Mutex<Status>,
    ready: Mutex<Option<(Update, Vec<u8>)>>,
    operation: tokio::sync::Mutex<()>,
}
impl Default for Updates {
    fn default() -> Self {
        Self {
            status: Mutex::new(Status {
                version: env!("CARGO_PKG_VERSION").into(),
                client: ClientStatus::Idle,
                addon: "The client keeps the addon updated in your selected game folder.".into(),
            }),
            ready: Mutex::new(None),
            operation: tokio::sync::Mutex::new(()),
        }
    }
}
fn emit(app: &tauri::AppHandle) {
    let status = app.state::<Updates>().status.lock().unwrap().clone();
    let _ = app.emit("updates", status);
}
fn client(app: &tauri::AppHandle, status: ClientStatus) {
    app.state::<Updates>().status.lock().unwrap().client = status;
    emit(app);
}
fn addon(app: &tauri::AppHandle, message: String) {
    app.state::<Updates>().status.lock().unwrap().addon = message;
    emit(app);
}
fn notify(app: &tauri::AppHandle, message: &str) {
    let _ = app
        .notification()
        .builder()
        .title("Goldbook update")
        .body(message)
        .show();
}
fn cache(app: &tauri::AppHandle) -> Result<PathBuf> {
    Ok(app.path().app_local_data_dir()?.join("addon-update"))
}
fn public_key() -> String {
    let config: serde_json::Value =
        serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
    config["plugins"]["updater"]["pubkey"]
        .as_str()
        .unwrap()
        .to_owned()
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AddonBundle {
    pub version: String,
    pub sequence: u64,
    pub revision: String,
    pub files: BTreeMap<String, String>,
}
// Signed JSON avoids archive extraction and keeps every write inside Goldbook's folder.
pub fn verified_addon(bytes: &[u8], signature: &[u8], key: &str) -> Result<AddonBundle> {
    if bytes.len() > MAX_ADDON || signature.len() > 4096 {
        bail!("Addon update is too large");
    }
    let key = String::from_utf8(STANDARD.decode(key)?)?;
    let signature = String::from_utf8(STANDARD.decode(signature.trim_ascii())?)?;
    PublicKey::decode(&key)?.verify(bytes, &Signature::decode(&signature)?, false)?;
    let bundle: AddonBundle = serde_json::from_slice(bytes)?;
    semver::Version::parse(&bundle.version)?;
    if bundle.revision.len() != 40 || !bundle.revision.bytes().all(|c| c.is_ascii_hexdigit()) {
        bail!("Invalid addon revision");
    }
    if bundle.files.is_empty() || bundle.files.len() > 100 {
        bail!("Invalid addon file list");
    }
    for name in bundle.files.keys() {
        if !name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'.' || c == b'-' || c == b'_')
            || name.starts_with('.')
            || !(name.ends_with(".lua") || name == "Goldbook.toc")
        {
            bail!("Invalid addon file name");
        }
    }
    let toc = bundle
        .files
        .get("Goldbook.toc")
        .context("Missing addon manifest")?;
    if !toc
        .lines()
        .any(|line| line.trim() == format!("## Version: {}", bundle.version))
    {
        bail!("Addon version does not match its manifest");
    }
    for line in toc
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
    {
        if !bundle.files.contains_key(line) {
            bail!("Addon manifest references a missing file");
        }
    }
    Ok(bundle)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SignedAddon {
    payload: String,
    signature: String,
}
fn signed_addon(bytes: &[u8]) -> Result<AddonBundle> {
    let envelope: SignedAddon = serde_json::from_slice(bytes)?;
    verified_addon(
        &STANDARD.decode(envelope.payload)?,
        envelope.signature.as_bytes(),
        &public_key(),
    )
}
fn cached_bundle(app: &tauri::AppHandle) -> Result<(AddonBundle, Vec<u8>)> {
    let bytes = fs::read(cache(app)?.join("addon.json"))?;
    Ok((signed_addon(&bytes)?, bytes))
}

fn newer_than_bundled(bundle: &AddonBundle) -> bool {
    bundle.sequence >= env!("GOLDBOOK_ADDON_SEQUENCE").parse::<u64>().unwrap()
}
pub fn source(app: &tauri::AppHandle) -> Result<PathBuf> {
    if let Ok((bundle, _)) = cached_bundle(app)
        && newer_than_bundled(&bundle)
    {
        let directory = cache(app)?.join("files");
        if directory.exists() {
            fs::remove_dir_all(&directory)?;
        }
        fs::create_dir_all(&directory)?;
        for (name, content) in bundle.files {
            fs::write(directory.join(name), content)?;
        }
        return Ok(directory);
    }
    if cfg!(debug_assertions) {
        return Ok(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../addon/Goldbook"));
    }
    Ok(app.path().resource_dir()?.join("addon/Goldbook"))
}
async fn download(client: &reqwest::Client, url: &str, maximum: usize) -> Result<Vec<u8>> {
    let mut response = client.get(url).send().await?.error_for_status()?;
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if bytes.len() + chunk.len() > maximum {
            bail!("Update is too large");
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}
async fn update_addon(app: &tauri::AppHandle) -> Result<()> {
    if !app.state::<crate::AppState>().config.exists() {
        return Ok(());
    }
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()?;
    let bytes = download(&http, &format!("{ROOT}/addon.json"), MAX_ADDON).await?;
    let bundle = signed_addon(&bytes)?;
    if !newer_than_bundled(&bundle) {
        addon(
            app,
            "Your bundled addon is newer than the published update.".into(),
        );
        return Ok(());
    }
    if cached_bundle(app).is_ok_and(|(old, _)| old.sequence > bundle.sequence) {
        addon(
            app,
            "Your installed addon is newer than the published update.".into(),
        );
        return Ok(());
    }
    let changed = cached_bundle(app)
        .map(|(_, old)| old != bytes)
        .unwrap_or(true);
    let directory = cache(app)?;
    fs::create_dir_all(&directory)?;
    fs::write(directory.join("addon.json.tmp"), &bytes)?;
    fs::rename(
        directory.join("addon.json.tmp"),
        directory.join("addon.json"),
    )?;
    let state = app.state::<crate::AppState>();
    let _operation = state.operation.lock().await;
    // Re-read after taking the lock: a game-folder change may have happened during download.
    let settings = crate::settings::read(&state.config).prepare()?;
    let installed = goldbook_sync::install_addon(
        Some(Path::new(&settings.wow_dir)),
        &source(app)?,
        Some(&settings.api),
    )?;
    if installed.is_empty() {
        bail!("Choose your World of Warcraft folder in Settings to install the addon.");
    }
    let message = format!(
        "Addon {} installed in {} game {}. Type /reload in WoW, or restart it if Goldbook is new.",
        bundle.version,
        installed.len(),
        if installed.len() == 1 {
            "folder"
        } else {
            "folders"
        }
    );
    addon(app, message.clone());
    if changed {
        notify(app, &message);
    }
    drop(settings);
    Ok(())
}
async fn update_client(app: &tauri::AppHandle) -> Result<()> {
    if app.state::<Updates>().ready.lock().unwrap().is_some() {
        return Ok(());
    }
    client(app, ClientStatus::Checking);
    let update = app
        .updater_builder()
        .timeout(Duration::from_secs(120))
        .build()?
        .check()
        .await?;
    if let Some(update) = update {
        let version = update.version.clone();
        client(
            app,
            ClientStatus::Downloading {
                version: version.clone(),
            },
        );
        let bytes = update.download(|_, _| {}, || {}).await?;
        *app.state::<Updates>().ready.lock().unwrap() = Some((update, bytes));
        client(
            app,
            ClientStatus::Ready {
                version: version.clone(),
            },
        );
        notify(
            app,
            &format!("Goldbook {version} is downloaded. Open Goldbook to install and restart."),
        );
    } else {
        client(app, ClientStatus::Current);
    }
    Ok(())
}
#[tauri::command]
pub fn get_updates(app: tauri::AppHandle) -> Status {
    app.state::<Updates>().status.lock().unwrap().clone()
}
#[tauri::command]
pub async fn check_updates(app: tauri::AppHandle) {
    let updates = app.state::<Updates>();
    let Ok(_operation) = updates.operation.try_lock() else {
        return;
    };
    let (client_result, addon_result) = tokio::join!(update_client(&app), update_addon(&app));
    if let Err(error) = client_result {
        eprintln!("Client update failed: {error:#}");
        client(
            &app,
            ClientStatus::Failed {
                message:
                    "Client updates are unavailable. Check your connection and try again later."
                        .into(),
            },
        );
    }
    if let Err(error) = addon_result {
        eprintln!("Addon update failed: {error:#}");
        addon(&app, "The addon update could not be installed. Check your connection and game folder permissions, then try again.".into());
    }
}
#[tauri::command]
pub async fn install_update(app: tauri::AppHandle) -> std::result::Result<(), String> {
    let state = app.state::<Updates>();
    let _operation = state.operation.lock().await;
    let ready = state
        .ready
        .lock()
        .unwrap()
        .take()
        .ok_or("No downloaded client update is ready.")?;
    client(
        &app,
        ClientStatus::Installing {
            version: ready.0.version.clone(),
        },
    );
    if let Err(error) = ready.0.install(&ready.1) {
        let message = format!("Could not install the client update: {error}");
        *state.ready.lock().unwrap() = Some(ready);
        let version = state
            .ready
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .0
            .version
            .clone();
        client(&app, ClientStatus::Ready { version });
        return Err(message);
    }
    app.restart();
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn signed_addons_reject_tampering_paths_incomplete_files_and_wrong_versions() {
        let vectors: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/signed-addons.json")).unwrap();
        let key = vectors["publicKey"].as_str().unwrap();
        let verify = |name: &str| {
            let vector = &vectors[name];
            verified_addon(
                &STANDARD
                    .decode(vector["payload"].as_str().unwrap())
                    .unwrap(),
                vector["signature"].as_str().unwrap().as_bytes(),
                key,
            )
        };
        let valid = verify("valid").unwrap();
        assert_eq!(valid.version, "0.1.3");
        assert_eq!(valid.files["Core.lua"], "local _, ns = ...\n");
        for name in ["traversal", "missing", "version"] {
            assert!(verify(name).is_err(), "{name}");
        }
        let mut bytes = STANDARD
            .decode(vectors["valid"]["payload"].as_str().unwrap())
            .unwrap();
        bytes[10] ^= 1;
        assert!(
            verified_addon(
                &bytes,
                vectors["valid"]["signature"].as_str().unwrap().as_bytes(),
                key
            )
            .is_err()
        );
        assert!(verified_addon(&[], b"bad-signature", key).is_err());
        assert!(verified_addon(&vec![0; MAX_ADDON + 1], b"", key).is_err());
    }
}
