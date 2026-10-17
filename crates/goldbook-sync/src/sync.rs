use crate::{extract_account, extract_scans, extract_seller_snapshots, read_saved_variables};
use anyhow::{Result, anyhow};
use fs2::FileExt;
use goldbook_core::sha256;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::{Arc, LazyLock, Mutex},
    time::Duration,
};
use tokio::sync::Mutex as AsyncMutex;

pub type Logger = Arc<dyn Fn(&str) + Send + Sync>;
#[derive(Clone)]
pub struct SyncOptions {
    pub file: PathBuf,
    pub api: String,
    pub token: String,
    pub state_path: PathBuf,
    pub log: Logger,
}
#[derive(Debug, Default, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SyncResult {
    pub sent: u64,
    pub already_sent: u64,
    pub invalid: u64,
    pub failed: u64,
}
#[derive(Debug, Default, Serialize)]
struct State {
    uploaded: Vec<String>,
    accounts: BTreeMap<String, SentAccount>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SentAccount {
    payload: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    key_hash: Option<String>,
}
fn state_from_value(v: Value) -> Option<State> {
    let o = v.as_object()?;
    let uploaded = o
        .get("uploaded")?
        .as_array()?
        .iter()
        .map(|v| v.as_str().map(str::to_owned))
        .collect::<Option<Vec<_>>>()?;
    let mut accounts = BTreeMap::new();
    if let Some(a) = o.get("accounts") {
        for (id, entry) in a.as_object()? {
            let account = if let Some(payload) = entry.as_str() {
                SentAccount {
                    payload: payload.into(),
                    key_hash: None,
                }
            } else {
                {
                    let o = entry.as_object()?;
                    if o.get("keyHash").is_some_and(|v| !v.is_string()) {
                        return None;
                    }
                    serde_json::from_value(entry.clone()).ok()?
                }
            };
            accounts.insert(id.clone(), account);
        }
    }
    Some(State { uploaded, accounts })
}
fn read_state(path: &Path) -> Option<State> {
    match fs::read(path) {
        Ok(s) => serde_json::from_slice(&s).ok().and_then(state_from_value),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(State::default()),
        Err(_) => None,
    }
}
fn state_change<T>(path: &Path, update: impl FnOnce(&mut State, bool) -> Result<T>) -> Result<T> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent)?;
    let mut lock_path = path.as_os_str().to_owned();
    lock_path.push(".lock");
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(PathBuf::from(lock_path))?;
    lock.lock_exclusive()?;
    let loaded = read_state(path);
    let corrupt = loaded.is_none();
    let mut state = loaded.unwrap_or_default();
    let output = update(&mut state, corrupt)?;
    // Keep several full addon queues, which can contain 10,000 seller snapshots each.
    if state.uploaded.len() > 50_000 {
        state.uploaded.drain(..state.uploaded.len() - 50_000);
    }
    let mut temp = tempfile::NamedTempFile::new_in(parent)?;
    serde_json::to_writer(&mut temp, &state)?;
    temp.flush()?;
    temp.as_file().sync_all()?;
    temp.persist(path).map_err(|e| e.error)?;
    Ok(output)
}
pub fn api_url(api: &str, path: &str) -> Result<reqwest::Url> {
    let mut base = api.to_owned();
    if !base.ends_with('/') {
        base.push('/')
    }
    Ok(reqwest::Url::parse(&base)?.join(path.trim_start_matches('/'))?)
}
async fn upload(
    client: &reqwest::Client,
    options: &SyncOptions,
    path: &str,
    body: String,
) -> Result<Option<u16>> {
    let response = client
        .post(api_url(&options.api, path)?)
        .bearer_auth(&options.token)
        .header("content-type", "application/json")
        .body(body)
        .send()
        .await?;
    let status = response.status();
    if status.is_success() {
        return Ok(None);
    }
    let text = response.text().await.unwrap_or_default();
    if status.as_u16() == 409 && path == "api/account" {
        return Ok(Some(409));
    }
    Err(anyhow!("{} {}", status.as_u16(), text))
}
static FILE_LOCKS: LazyLock<Mutex<HashMap<PathBuf, std::sync::Weak<AsyncMutex<()>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
pub(crate) fn file_lock(path: &Path) -> Arc<AsyncMutex<()>> {
    let key = fs::canonicalize(path).unwrap_or_else(|_| {
        if path.is_absolute() {
            path.to_owned()
        } else {
            std::env::current_dir().unwrap_or_default().join(path)
        }
    });
    let mut locks = FILE_LOCKS.lock().unwrap_or_else(|e| e.into_inner());
    locks.retain(|_, l| l.strong_count() > 0);
    if let Some(lock) = locks.get(&key).and_then(std::sync::Weak::upgrade) {
        return lock;
    }
    let lock = Arc::new(AsyncMutex::new(()));
    locks.insert(key, Arc::downgrade(&lock));
    lock
}
pub async fn sync_file(options: &SyncOptions) -> Result<SyncResult> {
    let lock = file_lock(&options.file);
    let _guard = lock.lock().await;
    let mut result = SyncResult::default();
    if !options.file.exists() {
        return Ok(result);
    }
    let state = state_change(&options.state_path, |state, corrupt| {
        if corrupt {
            (options.log)(&format!(
                "{} is unreadable, starting again from an empty one",
                options.state_path.display()
            ))
        }
        Ok(State {
            uploaded: state.uploaded.clone(),
            accounts: state.accounts.clone(),
        })
    })?;
    let mut sent = state.uploaded.into_iter().collect::<HashSet<_>>();
    let saved = read_saved_variables(&options.file)?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()?;
    for queued in extract_scans(&saved)? {
        if sent.contains(&queued.id) {
            result.already_sent += 1;
            continue;
        }
        let scan = match queued.decode() {
            Ok(scan) => scan,
            Err(e) => {
                (options.log)(&format!("skipped {}: {e}", queued.label));
                result.invalid += 1;
                continue;
            }
        };
        if let Err(e) = upload(&client, options, "api/scans", serde_json::to_string(&scan)?).await {
            (options.log)(&format!("upload of {} failed: {e}", queued.label));
            result.failed += 1;
            return Ok(result);
        }
        state_change(&options.state_path, |state, _| {
            if !state.uploaded.contains(&queued.id) {
                state.uploaded.push(queued.id.clone())
            }
            Ok(())
        })?;
        sent.insert(queued.id);
        result.sent += 1;
        (options.log)(&format!(
            "uploaded {}: {} items ({})",
            queued.label,
            scan.rows.len(),
            scan.mode
        ));
    }
    let mut pending = Vec::new();
    for queued in extract_seller_snapshots(&saved)? {
        if sent.contains(&queued.id) {
            result.already_sent += 1;
            continue;
        }
        match queued.decode() {
            Ok(snapshot) => {
                sent.insert(queued.id.clone());
                pending.push((queued.id, serde_json::to_string(&snapshot)?));
            }
            Err(e) => {
                (options.log)(&format!("skipped seller snapshot: {e}"));
                result.invalid += 1;
            }
        }
    }
    let mut pending = pending.into_iter().peekable();
    while pending.peek().is_some() {
        let mut ids = Vec::new();
        let mut body = String::from("[");
        while let Some((_, payload)) = pending.peek() {
            // Bound typical batches by bytes too. A single large snapshot keeps
            // the existing server body limit instead of being split or discarded.
            if !ids.is_empty()
                && (ids.len() == goldbook_core::MAX_SELLER_BATCH
                    || body.len() + payload.len() + 2 > 8 * 1024 * 1024)
            {
                break;
            }
            let (id, payload) = pending.next().unwrap();
            if !ids.is_empty() {
                body.push(',');
            }
            body.push_str(&payload);
            ids.push(id);
        }
        body.push(']');
        if let Err(e) = upload(&client, options, "api/sellers/batch", body).await {
            (options.log)(&format!(
                "upload of {} seller snapshots failed: {e}",
                ids.len()
            ));
            result.failed += ids.len() as u64;
            return Ok(result);
        }
        state_change(&options.state_path, |state, _| {
            let known = state.uploaded.iter().cloned().collect::<HashSet<_>>();
            state
                .uploaded
                .extend(ids.iter().filter(|id| !known.contains(*id)).cloned());
            Ok(())
        })?;
        result.sent += ids.len() as u64;
        (options.log)(&format!(
            "uploaded {} seller snapshots in one batch",
            ids.len()
        ));
    }
    let mut account = match extract_account(&saved) {
        Ok(Some(a)) => a,
        Ok(None) => return Ok(result),
        Err(e) => {
            (options.log)(&format!("skipped account: {e}"));
            result.invalid += 1;
            return Ok(result);
        }
    };
    let payload = sha256(serde_json::to_vec(&account)?);
    let last = state.accounts.get(&account.id);
    if last.is_some_and(|last| last.payload == payload) {
        result.already_sent += 1;
        return Ok(result);
    }
    account.previous_key_hash = last
        .filter(|last| last.key_hash.as_deref() != Some(&account.key_hash))
        .and_then(|last| last.key_hash.clone());
    let shown = format!("{}-{}", &account.id[..4], &account.id[4..]);
    match upload(
        &client,
        options,
        "api/account",
        serde_json::to_string(&account)?,
    )
    .await
    {
        Ok(Some(409)) => {
            (options.log)(&format!(
                "account {shown} belongs to another key on the server"
            ));
            result.invalid += 1
        }
        Err(e) => {
            (options.log)(&format!("upload of account {shown} failed: {e}"));
            result.failed += 1
        }
        Ok(_) => {
            state_change(&options.state_path, |state, _| {
                state.accounts.insert(
                    account.id.clone(),
                    SentAccount {
                        payload,
                        key_hash: Some(account.key_hash.clone()),
                    },
                );
                Ok(())
            })?;
            (options.log)(&format!(
                "uploaded account {shown}: {} characters",
                account.characters.len()
            ));
            result.sent += 1
        }
    }
    Ok(result)
}
