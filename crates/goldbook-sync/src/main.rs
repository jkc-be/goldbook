use anyhow::{Result, bail};
use clap::{Parser, Subcommand};
use goldbook_sync::{
    SyncOptions, WatchFile, WatchOptions, default_state_path, saved_variables_files, sync_file,
    watch_files,
};
use std::{path::PathBuf, sync::Arc};
#[derive(Subcommand)]
enum InstallCommand {
    /// Install the bundled addon into each installed game flavor.
    Install {
        #[arg(long)]
        wow: Option<PathBuf>,
        /// Copy this addon folder instead of the bundled addon.
        #[arg(long)]
        source: Option<PathBuf>,
        #[arg(long)]
        website: Option<String>,
    },
}
#[derive(Parser)]
#[command(about = "Upload Goldbook scans and characters from World of Warcraft SavedVariables")]
struct Args {
    #[command(subcommand)]
    command: Option<InstallCommand>,
    #[arg(long, env = "GOLDBOOK_API", default_value = "http://localhost:8787")]
    api: String,
    #[arg(long, env = "GOLDBOOK_TOKEN")]
    token: Option<String>,
    #[arg(long)]
    wow: Option<PathBuf>,
    #[arg(long)]
    file: Vec<PathBuf>,
    #[arg(long,default_value_os_t=default_state_path())]
    state: PathBuf,
    #[arg(long)]
    once: bool,
}
#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    if let Some(InstallCommand::Install {
        wow,
        source,
        website,
    }) = args.command
    {
        let targets = match source {
            Some(source) => {
                goldbook_sync::install_addon(wow.as_deref(), &source, website.as_deref())?
            }
            None => goldbook_sync::install_bundled_addon(wow.as_deref(), website.as_deref())?,
        };
        if targets.is_empty() {
            bail!("No World of Warcraft AddOns folder found. Pass --wow and launch the game once.")
        }
        for path in targets {
            println!("installed {}", path.display());
        }
        return Ok(());
    }
    let Some(token) = args.token.filter(|s| !s.is_empty()) else {
        bail!("No upload token. Pass --token or set GOLDBOOK_TOKEN.")
    };
    let files = if args.file.is_empty() {
        saved_variables_files(args.wow.as_deref())
    } else {
        args.file
    };
    if files.is_empty() {
        bail!("No World of Warcraft account folder found. Pass --wow or --file.")
    }
    let log: goldbook_sync::Logger = Arc::new(|line| println!("{line}"));
    if args.once {
        let mut failed = false;
        for file in files {
            match sync_file(&SyncOptions {
                file: file.clone(),
                api: args.api.clone(),
                token: token.clone(),
                state_path: args.state.clone(),
                log: log.clone(),
            })
            .await
            {
                Ok(result) => failed |= result.failed + result.invalid > 0,
                Err(e) => {
                    log(&format!("{}: {e}", file.display()));
                    failed = true
                }
            }
        }
        if failed {
            std::process::exit(1)
        }
    } else {
        let handle = watch_files(WatchOptions {
            interval: Some(std::time::Duration::from_secs(15)),
            files: files
                .into_iter()
                .map(|file| WatchFile {
                    file,
                    token: token.clone(),
                })
                .collect(),
            api: args.api,
            state_path: args.state,
            log,
        })?;
        tokio::signal::ctrl_c().await?;
        handle.close();
    }
    Ok(())
}
