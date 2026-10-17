use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};
use url::Url;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub wow_dir: String,
    pub api: String,
    pub token: String,
    pub battlenet_session: Option<String>,
    pub upload_tokens: BTreeMap<String, String>,
    pub open_at_login: bool,
    pub auto_sync: bool,
    pub sync_minutes: u32,
}

pub const MAX_SYNC_MINUTES: u32 = 1440;
pub const DEFAULT_API: &str = "https://app.jkc-be.com/goldbook";

impl Default for Settings {
    fn default() -> Self {
        Self {
            wow_dir: goldbook_sync::default_wow_dir()
                .to_string_lossy()
                .into_owned(),
            api: DEFAULT_API.into(),
            token: String::new(),
            battlenet_session: None,
            upload_tokens: BTreeMap::new(),
            open_at_login: true,
            auto_sync: true,
            sync_minutes: 15,
        }
    }
}

pub fn normalize_api(input: &str) -> Result<String> {
    let input = input.trim();
    if input.is_empty() {
        bail!("Enter the server address, such as http://localhost:8787.");
    }
    let text = if input.contains("://") {
        input.to_owned()
    } else {
        let host = input
            .split('/')
            .next()
            .unwrap_or_default()
            .split(':')
            .next()
            .unwrap_or_default();
        format!(
            "{}://{input}",
            if host == "localhost" || host == "127.0.0.1" {
                "http"
            } else {
                "https"
            }
        )
    };
    let mut url =
        Url::parse(&text).context("Enter the server address, such as http://localhost:8787.")?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        bail!("The server address must start with http:// or https://.");
    }
    url.set_username("")
        .map_err(|()| anyhow::anyhow!("Invalid server address"))?;
    url.set_password(None)
        .map_err(|()| anyhow::anyhow!("Invalid server address"))?;
    url.set_query(None);
    url.set_fragment(None);
    Ok(url.to_string().trim_end_matches('/').to_owned())
}

impl Settings {
    pub fn reconcile_token(&mut self, previous: &Self, edited: bool) {
        if normalize_api(&previous.api).ok().as_deref() == Some(self.api.as_str()) {
            self.upload_tokens.clone_from(&previous.upload_tokens);
            self.battlenet_session
                .clone_from(&previous.battlenet_session);
            if !edited {
                self.token.clone_from(&previous.token);
            }
        } else {
            self.upload_tokens.clear();
            self.battlenet_session = None;
            if self.token == previous.token {
                self.token.clear();
            }
        }
    }

    pub fn prepare(mut self) -> Result<Self> {
        self.wow_dir = self.wow_dir.trim().into();
        self.token = self.token.trim().into();
        if self.wow_dir.is_empty() {
            bail!("Choose your World of Warcraft folder.");
        }
        self.api = normalize_api(&self.api)?;
        self.sync_minutes = self.sync_minutes.clamp(1, MAX_SYNC_MINUTES);
        Ok(self)
    }
}

pub fn read(file: &Path) -> Settings {
    fs::read(file)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

pub fn write(file: &Path, settings: &Settings) -> Result<()> {
    use std::io::Write;
    if let Some(parent) = file.parent() {
        fs::create_dir_all(parent)?;
    }
    let temporary = file.with_extension("json.tmp");
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut output = options.open(&temporary)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        output.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    output.write_all(&serde_json::to_vec(settings)?)?;
    output.sync_all()?;
    drop(output);
    fs::rename(temporary, file)?;
    Ok(())
}

pub fn state_path(api: &str) -> Result<PathBuf> {
    let hash = hex::encode(Sha256::digest(normalize_api(api)?.as_bytes()));
    Ok(dirs::home_dir()
        .context("Cannot find your home folder")?
        .join(".config/goldbook")
        .join(format!("desktop-{hash}.json")))
}

// Electron used this directory; reusing it preserves existing settings.
pub fn config_path() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("GOLDBOOK_CONFIG") {
        return Ok(PathBuf::from(path));
    }
    #[cfg(target_os = "macos")]
    let directory = dirs::home_dir()
        .context("Cannot find your home folder")?
        .join("Library/Application Support/Goldbook");
    #[cfg(not(target_os = "macos"))]
    let directory = dirs::config_dir()
        .context("Cannot find your settings folder")?
        .join("Goldbook");
    Ok(directory.join("settings.json"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn normalizes_server_and_preserves_path() {
        assert_eq!(
            normalize_api(" app.jkc-be.com/goldbook/?q=no#no ").unwrap(),
            "https://app.jkc-be.com/goldbook"
        );
        assert_eq!(
            normalize_api("localhost:8787").unwrap(),
            "http://localhost:8787"
        );
        assert_eq!(
            normalize_api("http://user:password@localhost:8787/nested/").unwrap(),
            "http://localhost:8787/nested"
        );
        assert!(normalize_api("file:///tmp").is_err());
        assert!(normalize_api("").is_err());
        assert_ne!(
            state_path("localhost:8787").unwrap(),
            state_path("localhost:8788").unwrap()
        );
        assert_eq!(
            state_path("localhost:8787/").unwrap(),
            state_path("http://localhost:8787").unwrap()
        );
    }
    #[test]
    fn saving_a_stale_form_reuses_credentials_but_explicit_edits_win() {
        let previous = Settings {
            token: "gb_saved".into(),
            battlenet_session: Some("saved-session".into()),
            upload_tokens: BTreeMap::from([("fingerprint".into(), "account-token".into())]),
            ..Settings::default()
        };
        let mut stale = Settings::default();
        stale.reconcile_token(&previous, false);
        assert_eq!(stale.token, "gb_saved");
        assert_eq!(stale.battlenet_session.as_deref(), Some("saved-session"));
        assert_eq!(stale.upload_tokens["fingerprint"], "account-token");
        let mut reset = Settings::default();
        reset.reconcile_token(&previous, true);
        assert_eq!(reset.token, "");
        let mut changed_server = previous.clone();
        changed_server.api = "https://custom.example".into();
        changed_server.reconcile_token(&previous, false);
        assert_eq!(changed_server.token, "");
        assert!(changed_server.upload_tokens.is_empty());
        assert!(changed_server.battlenet_session.is_none());
        changed_server.token = "custom-token".into();
        changed_server.reconcile_token(&previous, true);
        assert_eq!(changed_server.token, "custom-token");
    }
    #[test]
    fn fresh_install_leaves_the_token_for_automatic_setup() {
        let settings = Settings {
            wow_dir: "/game".into(),
            ..Settings::default()
        };
        let settings = settings.prepare().unwrap();
        assert_eq!(settings.api, DEFAULT_API);
        assert_eq!(settings.token, "");
    }
    #[test]
    fn syncs_automatically_every_15_minutes_and_clamps_the_interval() {
        let base = || Settings {
            wow_dir: "/game".into(),
            token: "t".into(),
            ..Settings::default()
        };
        let old: Settings = serde_json::from_str(r#"{"wowDir":"/game","token":"t"}"#).unwrap();
        assert!(old.auto_sync);
        assert_eq!(old.sync_minutes, 15);
        let minutes = |value: u32| {
            Settings {
                sync_minutes: value,
                ..base()
            }
            .prepare()
            .unwrap()
            .sync_minutes
        };
        assert_eq!(minutes(5), 5);
        assert_eq!(minutes(0), 1);
        assert_eq!(minutes(99999), MAX_SYNC_MINUTES);
    }
    #[test]
    fn roundtrip_and_private_permissions() {
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("settings.json");
        let saved = Settings {
            wow_dir: "/game".into(),
            api: "http://localhost:8787".into(),
            token: "test-token".into(),
            battlenet_session: Some("enrollment-session".into()),
            upload_tokens: BTreeMap::new(),
            open_at_login: false,
            auto_sync: false,
            sync_minutes: 30,
        };
        write(&file, &saved).unwrap();
        assert_eq!(read(&file).token, "test-token");
        assert_eq!(
            read(&file).battlenet_session.as_deref(),
            Some("enrollment-session")
        );
        assert!(!read(&file).open_at_login);
        assert!(!read(&file).auto_sync);
        assert_eq!(read(&file).sync_minutes, 30);
        write(&file, &saved).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(file).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }
}
