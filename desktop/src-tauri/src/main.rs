#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod battlenet;
mod registration;
mod settings;
mod updates;
mod website;

use goldbook_sync::{ServerData, WatchHandle, WatchOptions};
use serde::{Deserialize, Serialize};
use settings::Settings;
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    webview::{PageLoadEvent, WebviewBuilder},
    Emitter, LogicalPosition, LogicalSize, Manager, State, WebviewUrl,
};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

const SITE: &str = "site";

// Under this mark web/style.css hides the website's rail and brand, which the
// app's own rail replaces. WebView2 can run this before the document element exists.
const EMBED: &str = "{ const mark = () => document.documentElement && (document.documentElement.dataset.embed = 'desktop'); if (!mark()) new MutationObserver((_, watch) => mark() && watch.disconnect()).observe(document, { childList: true }); }";

#[derive(Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Theme {
    #[default]
    Light,
    Dark,
}

impl Theme {
    // The website's theme.js reads the stored choice before its first paint, so
    // later pages in the view open in the app's theme.
    fn script(self) -> &'static str {
        match self {
            Theme::Light => "document.documentElement.dataset.theme = 'light'; try { localStorage.setItem('goldbook-theme', 'light'); } catch {}",
            Theme::Dark => "document.documentElement.dataset.theme = 'dark'; try { localStorage.setItem('goldbook-theme', 'dark'); } catch {}",
        }
    }
}

#[derive(Clone, Serialize)]
struct Snapshot {
    files: usize,
    message: String,
}

struct AppState {
    config: PathBuf,
    service: Mutex<Option<Arc<WatchHandle>>>,
    account_files: Mutex<Vec<PathBuf>>,
    snapshot: Mutex<Snapshot>,
    website: Mutex<Option<website::Handoff>>,
    // The server the website view last showed, and whether it holds a web login.
    site: Mutex<(String, bool)>,
    theme: Mutex<Theme>,
    operation: tokio::sync::Mutex<()>,
    generation: AtomicU64,
    battlenet_login: AtomicU64,
}

fn publish(app: &tauri::AppHandle, snapshot: Snapshot) {
    *app.state::<AppState>().snapshot.lock().unwrap() = snapshot.clone();
    let _ = app.emit("status", &snapshot);
    if let Some(tray) = app.tray_by_id("goldbook") {
        let _ = tray.set_tooltip(Some(format!("Goldbook: {}", snapshot.message)));
    }
}

fn watching_message(count: usize, auto: bool) -> String {
    match count {
        0 => "No World of Warcraft account folder yet. Log in once, then save again.".into(),
        _ if !auto => "Automatic sync is off. Use Sync now to upload.".into(),
        1 => "Watching 1 account folder. Type /reload or log out after a scan.".into(),
        n => format!("Watching {n} account folders. Type /reload or log out after a scan."),
    }
}

fn spoken_list(list: &str) -> String {
    match list.rsplit_once(", ") {
        Some((head, last)) => format!("{head} and {last}"),
        None => list.to_owned(),
    }
}

fn describe_log(line: &str) -> Option<String> {
    // The error after " failed: " can quote a server's reply, so it decides
    // before the upload branches below look at the line.
    if let Some(rest) = line.strip_prefix("server prices for ") {
        let failed = rest.find(" failed: ");
        return match rest.find(" written to ") {
            Some(at) if failed.is_none_or(|failed| at < failed) => Some(format!(
                "Prices for {} updated from the server. /reload to load them.",
                spoken_list(&rest[..at])
            )),
            _ if failed.is_some() => Some(
                "Goldbook could not download prices from the server. It will try again.".into(),
            ),
            _ => None,
        };
    }
    if line.contains("this account is blocked") {
        return Some("The server has blocked uploads from this WoW account.".into());
    }
    if line.starts_with("uploaded account ") {
        let count = line.rsplit(": ").next()?.split(' ').next()?;
        return Some(format!(
            "Uploaded {count} {}.",
            if count == "1" {
                "character"
            } else {
                "characters"
            }
        ));
    }
    if line.starts_with("uploaded sellers for ") {
        let count = line.rsplit(": ").next()?.split(' ').next()?;
        return Some(format!("Seller snapshot uploaded, {count} offers."));
    }
    if line.starts_with("uploaded ") {
        let summary = line.rsplit(": ").next()?;
        let count = summary.split(' ').next()?;
        return Some(format!(
            "{} uploaded, {count} items.",
            if summary.contains("replicate") {
                "Full scan"
            } else {
                "Quick scan"
            }
        ));
    }
    if line.contains("another key") {
        return Some("This account belongs to another key on the server.".into());
    }
    if line.starts_with("skipped ") {
        return Some(
            "Goldbook skipped data it could not read. It will send the next update.".into(),
        );
    }
    if line.starts_with("upload of ") {
        return Some(
            if line.contains("401") {
                "The server refused this app's upload access. Check Settings or contact the server administrator."
            } else {
                "An upload failed. Goldbook will try again."
            }
            .into(),
        );
    }
    if line.contains("unreadable") {
        return Some("Goldbook could not read its saved state, so it started again.".into());
    }
    None
}

fn apply_login(app: &tauri::AppHandle, enabled: bool) -> anyhow::Result<()> {
    if cfg!(debug_assertions) {
        return Ok(());
    }
    if enabled {
        app.autolaunch().enable()?;
    } else {
        app.autolaunch().disable()?;
    }
    #[cfg(target_os = "linux")]
    if let Some(config) = dirs::config_dir() {
        let old = config.join("autostart/goldbook.desktop");
        if old.exists() {
            std::fs::remove_file(old)?;
        }
    }
    Ok(())
}

fn apply(
    app: &tauri::AppHandle,
    settings: &Settings,
    setup: registration::UploadSetup,
) -> anyhow::Result<()> {
    let state = app.state::<AppState>();
    let generation = state.generation.fetch_add(1, Ordering::SeqCst) + 1;
    if let Some(previous) = state.service.lock().unwrap().take() {
        previous.close();
    }
    let files = setup.files;
    *state.account_files.lock().unwrap() = setup.known_files;
    let count = files.len();
    publish(
        app,
        Snapshot {
            files: count,
            message: if setup.blocked > 0 {
                format!(
                    "{} {blocked} WoW account(s) blocked by the server.",
                    watching_message(count, settings.auto_sync),
                    blocked = setup.blocked
                )
            } else {
                watching_message(count, settings.auto_sync)
            },
        },
    );
    let handle = app.clone();
    let log = Arc::new(move |line: &str| {
        if handle.state::<AppState>().generation.load(Ordering::SeqCst) != generation {
            return;
        }
        if let Some(message) = describe_log(line) {
            publish(
                &handle,
                Snapshot {
                    files: count,
                    message,
                },
            );
        }
    });
    let service = goldbook_sync::watch_files(WatchOptions {
        files,
        api: settings.api.clone(),
        state_path: settings::state_path(&settings.api)?,
        interval: settings
            .auto_sync
            .then(|| Duration::from_secs(u64::from(settings.sync_minutes) * 60)),
        log,
    })?;
    *state.service.lock().unwrap() = Some(Arc::new(service));
    Ok(())
}

#[derive(Serialize)]
struct InitialState {
    settings: Settings,
    status: Snapshot,
    configured: bool,
}

#[tauri::command]
fn get_state(state: State<'_, AppState>) -> InitialState {
    InitialState {
        settings: settings::read(&state.config),
        status: state.snapshot.lock().unwrap().clone(),
        configured: state.config.exists(),
    }
}

#[tauri::command]
async fn choose_folder(app: tauri::AppHandle) -> Result<Option<String>, String> {
    let current = settings::read(&app.state::<AppState>().config).wow_dir;
    let (tx, rx) = tokio::sync::oneshot::channel();
    app.dialog()
        .file()
        .set_title("Choose the World of Warcraft folder")
        .set_directory(current)
        .pick_folder(move |folder| {
            let _ = tx.send(folder.map(|p| p.to_string()));
        });
    rx.await.map_err(|e| e.to_string())
}

#[derive(Serialize)]
struct Reply {
    ok: bool,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    settings: Option<Settings>,
}

#[tauri::command]
fn cancel_battlenet_login(app: tauri::AppHandle) {
    app.state::<AppState>()
        .battlenet_login
        .fetch_add(1, Ordering::SeqCst);
}

#[tauri::command]
async fn battlenet_login(app: tauri::AppHandle) -> Reply {
    let state = app.state::<AppState>();
    let attempt = state.battlenet_login.fetch_add(1, Ordering::SeqCst) + 1;
    let result = async {
        if !state.config.exists() {
            anyhow::bail!("Save your World of Warcraft folder and server in Settings first.");
        }
        let saved = settings::read(&state.config).prepare()?;
        let api = saved.api;
        let login = battlenet::start(&api).await?;
        app.emit_to("main", "battlenet-code", &login.user_code)?;
        let files = state.snapshot.lock().unwrap().files;
        publish(
            &app,
            Snapshot {
                files,
                message: "Waiting for Battle.net sign-in in your browser.".into(),
            },
        );
        app.opener()
            .open_url(&login.authorization_url, None::<&str>)
            .map_err(|_| {
                anyhow::anyhow!("Goldbook could not open your browser for Battle.net sign-in.")
            })?;
        let session = battlenet::finish(&api, login, || {
            state.battlenet_login.load(Ordering::SeqCst) != attempt
        })
        .await?;
        let _operation = state.operation.lock().await;
        if state.battlenet_login.load(Ordering::SeqCst) != attempt {
            anyhow::bail!("Battle.net sign-in was cancelled.");
        }
        let mut settings = settings::read(&state.config).prepare()?;
        if settings.api != api {
            anyhow::bail!(
                "The server changed during sign-in. Sign in again for the selected server."
            );
        }
        settings.battlenet_session = Some(session);
        settings.upload_tokens.clear();
        // An explicit sign-in switches this server to verified account setup.
        settings.token.clear();
        stop_sync(&app);
        settings::write(&state.config, &settings)?;
        connect(&app, settings).await
    }
    .await;
    match result {
        Ok(settings) => Reply {
            ok: true,
            message: "Signed in with Battle.net. Uploads are ready.".into(),
            settings: Some(settings),
        },
        Err(error) => Reply {
            ok: false,
            message: error.to_string(),
            settings: None,
        },
    }
}

async fn check_upload(settings: &Settings) -> anyhow::Result<()> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    let response = client
        .post(goldbook_sync::api_url(&settings.api, "/api/scans")?)
        .bearer_auth(&settings.token)
        .header("content-type", "application/json")
        .body("{}")
        .send()
        .await
        .map_err(|_| anyhow::anyhow!("Goldbook cannot reach that server."))?;
    match response.status().as_u16() {
        400 | 200..=299 => Ok(()),
        401 => anyhow::bail!("The server refused this app's upload access. Check Settings or contact the server administrator."),
        503 => anyhow::bail!("That server has no upload token configured."),
        code => anyhow::bail!("The server answered {code}."),
    }
}

fn stop_sync(app: &tauri::AppHandle) {
    let state = app.state::<AppState>();
    state.generation.fetch_add(1, Ordering::SeqCst);
    let previous = state.service.lock().unwrap().take();
    if let Some(previous) = previous {
        previous.close();
    }
}

async fn connect(app: &tauri::AppHandle, mut settings: Settings) -> anyhow::Result<Settings> {
    let state = app.state::<AppState>();
    let setup = registration::prepare_uploads(&mut settings, &state.config).await?;
    let _ = app.emit_to("main", "upload-ready", ());
    apply(app, &settings, setup)?;
    Ok(settings)
}

#[tauri::command]
async fn save(app: tauri::AppHandle, input: Settings, token_edited: bool) -> Reply {
    let state = app.state::<AppState>();
    let _operation = state.operation.lock().await;
    let result = async {
        let mut settings = input.prepare()?;
        let previous = settings::read(&state.config);
        settings.reconcile_token(&previous, token_edited);
        let source = updates::source(&app)?;
        let game = PathBuf::from(&settings.wow_dir);
        let website = settings.api.clone();
        let installed = tauri::async_runtime::spawn_blocking(move || goldbook_sync::install_addon(Some(&game), &source, Some(&website))).await??;
        if installed.is_empty() { anyhow::bail!("Choose the World of Warcraft folder that contains a game such as _retail_ or _classic_."); }
        apply_login(&app, settings.open_at_login)?;
        stop_sync(&app);
        settings::write(&state.config, &settings)?;
        let settings = connect(&app, settings).await?;
        if !registration::needs_registration(&settings) {
            check_upload(&settings).await?;
        }
        let message = format!("Installed the addon in {} game {}. Restart World of Warcraft if this is the first time.", installed.len(), if installed.len() == 1 { "folder" } else { "folders" });
        Ok::<_, anyhow::Error>((settings, message))
    }.await;
    match result {
        Ok((settings, message)) => Reply {
            ok: true,
            message,
            settings: Some(settings),
        },
        Err(error) => Reply {
            ok: false,
            message: error.to_string(),
            settings: Some(settings::read(&state.config)),
        },
    }
}

async fn do_sync(app: &tauri::AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();
    let service = state.service.lock().unwrap().clone();
    if let Some(service) = service {
        let results = service.sync_now().await.map_err(|e| e.to_string())?;
        let mut any_update = false;
        for result in &results {
            if result.sent + result.invalid + result.failed > 0 {
                any_update = true;
            }
        }
        // A written file or a failed download has already put its message in the status line.
        if results.iter().all(|result| result.failed == 0) {
            for (_, outcome) in service.refresh_server_data().await {
                if matches!(outcome, Ok(ServerData::Written { .. }) | Err(_)) {
                    any_update = true;
                }
            }
        }
        if !any_update {
            let count = state.snapshot.lock().unwrap().files;
            let message = if count == 0 {
                watching_message(0, true)
            } else {
                "No new scans or character changes to upload.".into()
            };
            publish(
                app,
                Snapshot {
                    files: count,
                    message,
                },
            );
        }
    }
    Ok(())
}

#[tauri::command]
async fn sync_now(app: tauri::AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();
    let _operation = state.operation.lock().await;
    let running = state.service.lock().unwrap().is_some();
    let settings = settings::read(&state.config)
        .prepare()
        .map_err(|e| e.to_string())?;
    if !running || registration::needs_registration(&settings) {
        if !state.config.exists() {
            return Err("Choose your World of Warcraft folder in Settings and save first.".into());
        }
        connect(&app, settings).await.map_err(|e| e.to_string())?;
    }
    do_sync(&app).await
}

#[tauri::command]
fn get_logins(state: State<'_, AppState>) -> Vec<website::GameLogin> {
    website::game_logins(Path::new(&settings::read(&state.config).wow_dir))
}

#[tauri::command]
async fn open_site(app: tauri::AppHandle, account_id: Option<String>) -> Result<(), String> {
    let state = app.state::<AppState>();
    let _operation = state.operation.lock().await;
    let settings = settings::read(&state.config)
        .prepare()
        .map_err(|e| e.to_string())?;
    do_sync(&app).await?;
    let mut logins = website::game_logins(Path::new(&settings.wow_dir));
    if logins.is_empty() {
        app.opener()
            .open_url(format!("{}/#characters", settings.api), None::<&str>)
            .map_err(|e| e.to_string())?;
        let files = state.snapshot.lock().unwrap().files;
        publish(&app, Snapshot { files, message: "Log in to World of Warcraft and type /reload so Goldbook can fill in your web login.".into() });
        return Ok(());
    }
    let index = if let Some(id) = account_id {
        logins
            .iter()
            .position(|login| login.id == id)
            .ok_or("The selected game account is no longer saved.")?
    } else if logins.len() == 1 {
        0
    } else {
        return Err("Choose the World of Warcraft account you want to open.".into());
    };
    let page = website::handoff(&settings.api, logins.remove(index), Duration::from_secs(60))
        .await
        .map_err(|e| e.to_string())?;
    app.opener()
        .open_url(&page.url, None::<&str>)
        .map_err(|e| e.to_string())?;
    *state.website.lock().unwrap() = Some(page);
    Ok(())
}

// The website covers the window from the page's measured left and top edges.
// WebKit can inset the page below the macOS title bar even when the native
// webview fills the window. Include that inset when placing the website.
#[cfg(not(target_os = "linux"))]
#[tauri::command]
fn layout_site(
    window: tauri::Window,
    viewport_height: f64,
    left: f64,
    top: f64,
) -> Result<(), String> {
    let Some(site) = window.get_webview(SITE) else {
        return Ok(());
    };
    let size = window.inner_size().map_err(|e| e.to_string())?;
    let scale = window.scale_factor().map_err(|e| e.to_string())?;
    let size = size.to_logical::<f64>(scale);
    let top = (size.height - viewport_height).max(0.0) + top;
    site.set_bounds(tauri::Rect {
        position: LogicalPosition::new(left, top).into(),
        size: LogicalSize::new((size.width - left).max(0.0), (size.height - top).max(0.0)).into(),
    })
    .map_err(|e| e.to_string())
}

// GTK packs the window's webviews into a box, splits its height between them
// and ignores their bounds. Stack them in an overlay instead, so the website
// covers this page beside its rail as it does on macOS and Windows.
#[cfg(target_os = "linux")]
#[tauri::command]
fn layout_site(
    window: tauri::Window,
    viewport_height: f64,
    left: f64,
    top: f64,
) -> Result<(), String> {
    use gtk::prelude::*;
    let _ = viewport_height;
    let page = window
        .get_webview("main")
        .ok_or("The Goldbook window is closed.")?;
    page.with_webview(move |page| {
        let page = page.inner().upcast::<gtk::Widget>();
        let overlay = match page
            .parent()
            .map(|parent| parent.downcast::<gtk::Overlay>())
        {
            Some(Ok(overlay)) => overlay,
            Some(Err(parent)) => {
                let Ok(column) = parent.downcast::<gtk::Box>() else {
                    return;
                };
                let overlay = gtk::Overlay::new();
                column.remove(&page);
                overlay.add(&page);
                column.pack_start(&overlay, true, true, 0);
                overlay.show();
                overlay
            }
            None => return,
        };
        let Some(column) = overlay
            .parent()
            .and_then(|parent| parent.downcast::<gtk::Box>().ok())
        else {
            return;
        };
        // A new website view joins the box, next to the overlay.
        for site in column
            .children()
            .into_iter()
            .filter(|child| child.type_() == page.type_())
        {
            column.remove(&site);
            site.set_valign(gtk::Align::Fill);
            overlay.add_overlay(&site);
        }
        for site in overlay
            .children()
            .into_iter()
            .filter(|child| *child != page)
        {
            site.set_margin_start(left.ceil() as i32);
            site.set_margin_top(top.ceil() as i32);
        }
    })
    .map_err(|e| e.to_string())
}

// Shows the website inside the window. Prices are public. Characters need the
// web login, which the game's saved data supplies the same way Open website does.
#[tauri::command]
async fn show_view(
    app: tauri::AppHandle,
    name: String,
    account_id: Option<String>,
    viewport_height: f64,
    left: f64,
    top: f64,
) -> Result<(), String> {
    let window = app
        .get_window("main")
        .ok_or("The Goldbook window is closed.")?;
    let existing = window.get_webview(SITE);
    if name == "sync" {
        if let Some(site) = existing {
            site.hide().map_err(|e| e.to_string())?;
        }
        return Ok(());
    }
    if name != "prices" && name != "characters" {
        return Err("Goldbook has no such view.".into());
    }
    let state = app.state::<AppState>();
    let _operation = state.operation.lock().await;
    let settings = settings::read(&state.config)
        .prepare()
        .map_err(|e| e.to_string())?;
    let mut target = format!("{}/#{name}", settings.api);
    let signed_in = {
        let mut site = state.site.lock().unwrap();
        if site.0 != settings.api {
            *site = (settings.api.clone(), false);
        }
        site.1
    };
    if name == "characters" && !signed_in {
        let mut logins = website::game_logins(Path::new(&settings.wow_dir));
        let index = match (account_id, logins.len()) {
            (_, 0) => None,
            (Some(id), _) => Some(
                logins
                    .iter()
                    .position(|login| login.id == id)
                    .ok_or("The selected game account is no longer saved.")?,
            ),
            (None, 1) => Some(0),
            (None, _) => {
                return Err("Choose the World of Warcraft account you want to open.".into())
            }
        };
        if let Some(index) = index {
            let page =
                website::handoff(&settings.api, logins.remove(index), Duration::from_secs(60))
                    .await
                    .map_err(|e| e.to_string())?;
            target = page.url.clone();
            *state.website.lock().unwrap() = Some(page);
            state.site.lock().unwrap().1 = true;
        }
    }
    let url: url::Url = target
        .parse()
        .map_err(|_| "The server address is not valid.")?;
    match existing {
        Some(site) => {
            site.navigate(url).map_err(|e| e.to_string())?;
            site.show().map_err(|e| e.to_string())?;
        }
        None => {
            let origin = url::Url::parse(&settings.api).map_err(|e| e.to_string())?;
            let opener = app.clone();
            let builder = WebviewBuilder::new(SITE, WebviewUrl::External(url))
                .initialization_script(EMBED)
                .on_page_load(|site, page| {
                    if page.event() == PageLoadEvent::Finished {
                        let theme = *site.state::<AppState>().theme.lock().unwrap();
                        let _ = site.eval(theme.script());
                    }
                })
                // Pages stay on the Goldbook server. The sign-in handoff is a loopback page.
                .on_navigation(move |next| {
                    let local = next.host_str() == Some("127.0.0.1");
                    let same = next.origin() == origin.origin();
                    if !local && !same && matches!(next.scheme(), "http" | "https") {
                        let _ = opener.opener().open_url(next.as_str(), None::<&str>);
                    }
                    local || same
                });
            window
                .add_child(
                    builder,
                    LogicalPosition::new(0.0, 0.0),
                    LogicalSize::new(1.0, 1.0),
                )
                .map_err(|e| e.to_string())?;
        }
    }
    layout_site(window, viewport_height, left, top)
}

// The website's own theme switch is in the rail the view hides.
#[tauri::command]
fn set_theme(app: tauri::AppHandle, theme: Theme) -> Result<(), String> {
    *app.state::<AppState>().theme.lock().unwrap() = theme;
    match app.get_webview(SITE) {
        Some(site) => site.eval(theme.script()).map_err(|e| e.to_string()),
        None => Ok(()),
    }
}

// Not get_webview_window: once the website view is added the window holds two
// webviews, and Tauri then no longer returns it as a webview window.
fn show(app: &tauri::AppHandle) {
    if let Some(window) = app.get_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn main() {
    // WebKitGTK's DMABUF renderer kills the app with a Wayland protocol error
    // (Error 71) on some Mesa setups. Must be set before GTK starts.
    #[cfg(target_os = "linux")]
    if std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }

    let config = settings::config_path().expect("Cannot find the Goldbook settings folder");
    let state = AppState {
        config,
        service: Mutex::new(None),
        account_files: Mutex::new(Vec::new()),
        snapshot: Mutex::new(Snapshot {
            files: 0,
            message: "Open Settings to choose your game folder and server, then save.".into(),
        }),
        website: Mutex::new(None),
        site: Mutex::new((String::new(), false)),
        theme: Mutex::new(Theme::default()),
        operation: tokio::sync::Mutex::new(()),
        generation: AtomicU64::new(0),
        battlenet_login: AtomicU64::new(0),
    };
    tauri::Builder::default()
        .manage(state)
        .manage(updates::Updates::default())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_single_instance::init(|app, _, _| show(app)))
        .plugin({
            let builder = tauri_plugin_autostart::Builder::new();
            #[cfg(target_os = "macos")]
            let builder =
                builder.macos_launcher(tauri_plugin_autostart::MacosLauncher::LaunchAgent);
            builder.build()
        })
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            get_state,
            choose_folder,
            save,
            battlenet_login,
            cancel_battlenet_login,
            sync_now,
            get_logins,
            open_site,
            show_view,
            layout_site,
            set_theme,
            updates::get_updates,
            updates::check_updates,
            updates::install_update
        ])
        .setup(|app| {
            app.state::<updates::Updates>()
                .status
                .lock()
                .unwrap()
                .version = app.package_info().version.to_string();
            let open = MenuItem::with_id(app, "open", "Open Goldbook", true, None::<&str>)?;
            let sync = MenuItem::with_id(app, "sync", "Sync now", true, None::<&str>)?;
            let site = MenuItem::with_id(app, "site", "Open website", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Goldbook", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &sync, &site, &quit])?;
            TrayIconBuilder::with_id("goldbook")
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("Goldbook")
                .menu(&menu)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "quit" => app.exit(0),
                    "open" => show(app),
                    "sync" => {
                        let app = app.clone();
                        tauri::async_runtime::spawn(async move {
                            let _ = sync_now(app).await;
                        });
                    }
                    "site" => {
                        let app = app.clone();
                        tauri::async_runtime::spawn(async move {
                            if let Err(message) = open_site(app.clone(), None).await {
                                let files = app.state::<AppState>().snapshot.lock().unwrap().files;
                                publish(&app, Snapshot { files, message });
                                show(&app);
                            }
                        });
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if matches!(
                        event,
                        TrayIconEvent::Click {
                            button: MouseButton::Left,
                            button_state: MouseButtonState::Up,
                            ..
                        }
                    ) {
                        show(tray.app_handle());
                    }
                })
                .build(app)?;
            let updater = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    updates::check_updates(updater.clone()).await;
                    tokio::time::sleep(Duration::from_secs(6 * 3600)).await;
                }
            });
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    {
                        let state = handle.state::<AppState>();
                        let _operation = state.operation.lock().await;
                        let running = state.service.lock().unwrap().is_some();
                        let settings = settings::read(&state.config);
                        let discovered = goldbook_sync::saved_variables_files(Some(Path::new(
                            &settings.wow_dir,
                        )));
                        let changed = *state.account_files.lock().unwrap() != discovered;
                        if state.config.exists() && (!running || changed) {
                            let result = async {
                                let settings = settings::read(&state.config).prepare()?;
                                apply_login(&handle, settings.open_at_login)?;
                                goldbook_sync::install_addon(
                                    Some(Path::new(&settings.wow_dir)),
                                    &updates::source(&handle)?,
                                    Some(&settings.api),
                                )?;
                                connect(&handle, settings).await?;
                                Ok::<_, anyhow::Error>(())
                            }
                            .await;
                            if let Err(error) = result {
                                publish(
                                    &handle,
                                    Snapshot {
                                        files: 0,
                                        message: error.to_string(),
                                    },
                                );
                            }
                        }
                    }
                    tokio::time::sleep(Duration::from_secs(60)).await;
                }
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.app_handle().tray_by_id("goldbook").is_some() {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .build(tauri::generate_context!())
        .expect("Could not start Goldbook")
        .run(|app, event| {
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen { .. } = event {
                show(app);
            }
            if let tauri::RunEvent::Exit = event {
                let state = app.state::<AppState>();
                if let Some(service) = state.service.lock().unwrap().take() {
                    service.close();
                }
                state.website.lock().unwrap().take();
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    const WEB_STYLE: &str = include_str!("../../../web/style.css");
    const APP_STYLE: &str = include_str!("../../ui/style.css");

    fn rules(css: &str) -> impl Iterator<Item = (Vec<&str>, &str)> {
        css.split('}').filter_map(|rule| {
            let (selectors, body) = rule.split_once('{')?;
            let selectors = selectors.rsplit("*/").next()?;
            Some((selectors.split(',').map(str::trim).collect(), body))
        })
    }

    fn tokens<'a>(css: &'a str, selector: &str) -> BTreeMap<&'a str, &'a str> {
        rules(css)
            .filter(|(selectors, _)| selectors == &[selector])
            .flat_map(|(_, body)| body.split(';'))
            .filter_map(|line| line.trim().split_once(':'))
            .filter(|(name, _)| name.starts_with("--"))
            .map(|(name, value)| (name, value.trim()))
            .collect()
    }

    #[test]
    fn website_hides_its_rail_and_brand_under_the_embed_mark() {
        assert!(EMBED.contains("dataset.embed = 'desktop'"));
        for part in [".rail", ".brand"] {
            let selector = format!(":root[data-embed=\"desktop\"] {part}");
            assert!(
                rules(WEB_STYLE).any(|(selectors, body)| selectors.contains(&selector.as_str())
                    && body.contains("display: none")),
                "web/style.css no longer hides {part} in the desktop app"
            );
        }
    }

    #[test]
    fn server_price_lines_describe_written_and_failed_downloads() {
        let path =
            "/Applications/World of Warcraft/_classic_/Interface/AddOns/Goldbook/ServerData.lua";
        assert_eq!(
            describe_log(&format!(
                "server prices for Faramon-Horde written to {path}: 2 items"
            )),
            Some("Prices for Faramon-Horde updated from the server. /reload to load them.".into())
        );
        assert_eq!(
            describe_log(&format!(
                "server prices for Faramon-Horde, Pyrewood Village-Alliance written to {path}: 3 items"
            )),
            Some(
                "Prices for Faramon-Horde and Pyrewood Village-Alliance updated from the server. /reload to load them."
                    .into()
            )
        );
        assert_eq!(
            describe_log(&format!(
                "server prices for Area 52-Alliance, Faramon-Horde, Pyrewood Village-Alliance written to {path}: 9 items"
            )),
            Some(
                "Prices for Area 52-Alliance, Faramon-Horde and Pyrewood Village-Alliance updated from the server. /reload to load them."
                    .into()
            )
        );
        assert_eq!(
            describe_log(&format!(
                "server prices for Faramon-Horde unchanged in {path}"
            )),
            None
        );
        assert_eq!(
            describe_log("server prices for /Applications/World of Warcraft/_classic_ failed: export of Faramon-Horde answered 502 uploaded account written to unreadable another key"),
            Some(
                "Goldbook could not download prices from the server. It will try again.".into()
            )
        );
        assert_eq!(
            describe_log("uploaded account K7Q2-M9PX: 3 characters"),
            Some("Uploaded 3 characters.".into())
        );
    }

    #[test]
    fn theme_accepts_only_light_or_dark() {
        let dark: Theme = serde_json::from_str("\"dark\"").unwrap();
        assert_eq!(
            dark.script(),
            "document.documentElement.dataset.theme = 'dark'; try { localStorage.setItem('goldbook-theme', 'dark'); } catch {}"
        );
        let light: Theme = serde_json::from_str("\"light\"").unwrap();
        assert_eq!(
            light.script(),
            "document.documentElement.dataset.theme = 'light'; try { localStorage.setItem('goldbook-theme', 'light'); } catch {}"
        );
        for input in ["\"Dark\"", "\"sepia\"", "\"dark'; alert(1); '\"", "null"] {
            assert!(serde_json::from_str::<Theme>(input).is_err(), "{input}");
        }
    }

    #[test]
    fn app_colours_match_the_website() {
        for selector in [":root", ":root[data-theme=\"dark\"]"] {
            let web = tokens(WEB_STYLE, selector);
            let app = tokens(APP_STYLE, selector);
            assert!(app.len() > 20, "{selector} has {} tokens", app.len());
            for (name, value) in app {
                if name != "--tick" {
                    assert_eq!(web.get(name), Some(&value), "{selector} {name}");
                }
            }
        }
    }
}
