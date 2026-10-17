use crate::{Logger, SyncOptions, SyncResult, sync_file};
use anyhow::Result;
use notify::{RecursiveMode, Watcher};
use std::{
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};
use tokio::sync::{mpsc, watch};
#[derive(Clone)]
pub struct WatchFile {
    pub file: PathBuf,
    pub token: String,
}
#[derive(Clone)]
pub struct WatchOptions {
    pub files: Vec<WatchFile>,
    pub api: String,
    pub state_path: PathBuf,
    // How often each file is checked again. None uploads only on sync_now.
    pub interval: Option<Duration>,
    pub log: Logger,
}
const RETRY: Duration = Duration::from_secs(15);
pub struct WatchHandle {
    options: WatchOptions,
    stop: watch::Sender<bool>,
    closed: AtomicBool,
}
impl WatchHandle {
    pub fn close(&self) {
        self.closed.store(true, Ordering::Release);
        let _ = self.stop.send(true);
    }
    pub async fn sync_now(&self) -> Result<Vec<SyncResult>> {
        let mut results = Vec::new();
        for file in &self.options.files {
            results.push(sync_file(&self.options.for_file(file)).await?)
        }
        Ok(results)
    }
}
impl Drop for WatchHandle {
    fn drop(&mut self) {
        self.close()
    }
}
impl WatchOptions {
    fn for_file(&self, file: &WatchFile) -> SyncOptions {
        SyncOptions {
            file: file.file.clone(),
            api: self.api.clone(),
            token: file.token.clone(),
            state_path: self.state_path.clone(),
            log: self.log.clone(),
        }
    }
}
pub fn is_goldbook_write(changed: Option<&Path>, file: &Path) -> bool {
    match changed {
        None => true,
        Some(changed) => {
            let actual = changed.file_name();
            let expected = file.file_name();
            if cfg!(windows) {
                actual.zip(expected).is_some_and(|(a, b)| {
                    a.to_string_lossy()
                        .eq_ignore_ascii_case(&b.to_string_lossy())
                })
            } else {
                actual == expected
            }
        }
    }
}
pub fn watch_files(options: WatchOptions) -> Result<WatchHandle> {
    let (stop, _) = watch::channel(false);
    let (files, interval) = match options.interval {
        Some(interval) => (options.files.clone(), interval),
        None => (Vec::new(), RETRY),
    };
    for file in &files {
        let options = options.for_file(file);
        let mut stopped = stop.subscribe();
        tokio::spawn(async move {
            let (tx, mut rx) = mpsc::unbounded_channel();
            let file = options.file.clone();
            let log = options.log.clone();
            let watcher = notify::recommended_watcher(
                move |event: notify::Result<notify::Event>| match event {
                    Ok(event)
                        if event.paths.is_empty()
                            || event
                                .paths
                                .iter()
                                .any(|p| is_goldbook_write(Some(p), &file)) =>
                    {
                        let _ = tx.send(());
                    }
                    Err(e) => {
                        log(&format!("{}: {e}", file.display()));
                        let _ = tx.send(());
                    }
                    _ => (),
                },
            );
            let mut watcher = watcher.ok();
            if let Some(watcher) = &mut watcher
                && let Err(e) = watcher.watch(
                    options.file.parent().unwrap_or(Path::new(".")),
                    RecursiveMode::NonRecursive,
                )
            {
                (options.log)(&format!("{}: {e}", options.file.display()))
            }
            (options.log)(&format!("watching {}", options.file.display()));
            // Periodic passes also recover when a directory did not exist at startup or
            // an OS watcher loses events. Each pass is idempotent and serialized per file.
            // A failed pass is retried sooner than the interval.
            loop {
                if *stopped.borrow() {
                    break;
                }
                let healthy = match sync_file(&options).await {
                    Ok(result) => result.failed == 0,
                    Err(e) => {
                        (options.log)(&format!("{}: {e}", options.file.display()));
                        false
                    }
                };
                let wait = if healthy {
                    interval
                } else {
                    RETRY.min(interval)
                };
                let mut deadline = tokio::time::Instant::now() + wait;
                loop {
                    tokio::select! {_ = stopped.changed()=>{if *stopped.borrow(){return}},event=rx.recv(),if !rx.is_closed()=>{if event.is_some(){deadline=tokio::time::Instant::now()+Duration::from_secs(2)}},_ = tokio::time::sleep_until(deadline)=>break}
                }
            }
        });
    }
    Ok(WatchHandle {
        options,
        stop,
        closed: AtomicBool::new(false),
    })
}
