use anyhow::{ensure, Context, Result};
use std::{
    env, fs,
    path::{Path, PathBuf},
};
fn entries(path: &Path) -> Vec<PathBuf> {
    fs::read_dir(path)
        .map(|d| d.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default()
}
fn flavor(path: &Path) -> bool {
    path.file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|n| n.len() > 2 && n.starts_with('_') && n.ends_with('_'))
}
pub fn account_fingerprint(file: &Path) -> Result<String> {
    let mut path = file;
    for expected in ["Goldbook.lua", "SavedVariables"] {
        ensure!(
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.eq_ignore_ascii_case(expected)),
            "Expected a World of Warcraft account SavedVariables/Goldbook.lua path"
        );
        path = path.parent().context("Missing account folder")?;
    }
    let account = path
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .context("Account folder must have a nonempty UTF-8 name")?;
    path = path.parent().context("Missing Account folder")?;
    for expected in ["Account", "WTF"] {
        ensure!(
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.eq_ignore_ascii_case(expected)),
            "Expected a World of Warcraft WTF/Account folder"
        );
        path = path.parent().context("Missing game folder")?;
    }
    ensure!(
        flavor(path),
        "Expected a World of Warcraft game flavor folder"
    );
    Ok(goldbook_core::sha256(format!(
        "goldbook:wow-account:v1:{}",
        account.to_ascii_uppercase()
    )))
}
pub fn wow_dir_candidates() -> Vec<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        vec![PathBuf::from("/Applications/World of Warcraft")]
    }
    #[cfg(target_os = "windows")]
    {
        vec![
            PathBuf::from(
                env::var_os("ProgramFiles(x86)")
                    .unwrap_or_else(|| "C:\\Program Files (x86)".into()),
            )
            .join("World of Warcraft"),
            PathBuf::from(
                env::var_os("ProgramFiles").unwrap_or_else(|| "C:\\Program Files".into()),
            )
            .join("World of Warcraft"),
        ]
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        linux_wow_candidates(&dirs::home_dir().unwrap_or_default())
    }
}
pub fn linux_wow_candidates(home: &Path) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    let mut prefixes = vec![
        home.join(".wine"),
        home.join(".local/share/wineprefixes/wow"),
    ];
    for root in ["Games", ".var/app/net.lutris.Lutris/data/games"] {
        for p in entries(&home.join(root)) {
            prefixes.push(p.clone());
            if p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.eq_ignore_ascii_case("World of Warcraft"))
            {
                paths.push(p)
            }
        }
    }
    for root in [
        ".local/share/bottles/bottles",
        ".var/app/com.usebottles.bottles/data/bottles/bottles",
    ] {
        prefixes.extend(entries(&home.join(root)))
    }
    for root in [
        ".steam/steam",
        ".steam/debian-installation",
        ".local/share/Steam",
        ".var/app/com.valvesoftware.Steam/data/Steam",
        "snap/steam/common/.local/share/Steam",
    ] {
        prefixes.extend(
            entries(&home.join(root).join("steamapps/compatdata"))
                .into_iter()
                .map(|p| p.join("pfx")),
        )
    }
    let mut found = Vec::new();
    for prefix in prefixes {
        for program in ["Program Files (x86)", "Program Files"] {
            found.push(
                prefix
                    .join("drive_c")
                    .join(program)
                    .join("World of Warcraft"),
            )
        }
    }
    found.extend(paths);
    found
}
pub fn pick_wow_dir(candidates: &[PathBuf]) -> Option<PathBuf> {
    let existing = candidates.iter().filter(|p| p.is_dir()).collect::<Vec<_>>();
    existing
        .iter()
        .find(|p| entries(p).iter().any(|p| flavor(p)))
        .or_else(|| existing.first())
        .map(|p| (*p).clone())
}
pub fn default_wow_dir() -> PathBuf {
    let candidates = wow_dir_candidates();
    pick_wow_dir(&candidates)
        .or_else(|| candidates.into_iter().next())
        .unwrap_or_default()
}
pub fn flavor_dirs(wow_dir: Option<&Path>) -> Vec<PathBuf> {
    entries(wow_dir.unwrap_or(&default_wow_dir()))
        .into_iter()
        .filter(|p| p.is_dir() && flavor(p))
        .collect()
}
pub fn saved_variables_files(wow_dir: Option<&Path>) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for flavor in flavor_dirs(wow_dir) {
        for account in entries(&flavor.join("WTF/Account")) {
            let saved = account.join("SavedVariables");
            if saved.is_dir() {
                files.push(saved.join("Goldbook.lua"))
            }
        }
    }
    files.sort();
    files
}
fn copy_tree(source: &Path, destination: &Path) -> Result<()> {
    fs::create_dir_all(destination)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let target = destination.join(entry.file_name());
        if ty.is_dir() {
            copy_tree(&entry.path(), &target)?
        } else if ty.is_file() {
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}
pub fn install_addon(
    wow_dir: Option<&Path>,
    source: &Path,
    website: Option<&str>,
) -> Result<Vec<PathBuf>> {
    let mut installed = Vec::new();
    for flavor in flavor_dirs(wow_dir) {
        let addons = flavor.join("Interface/AddOns");
        if !addons.is_dir() {
            continue;
        }
        let destination = addons.join("Goldbook");
        let backup = addons.join(".Goldbook-backup");
        if backup.exists() {
            if destination.exists() {
                fs::remove_dir_all(&backup)?;
            } else {
                fs::rename(&backup, &destination)?;
            }
        }
        let staging = tempfile::Builder::new()
            .prefix(".Goldbook-update-")
            .tempdir_in(&addons)?;
        let prepared = staging.path().join("Goldbook");
        copy_tree(source, &prepared)?;
        if let Some(website) = website {
            let toc = prepared.join("Goldbook.toc");
            let original = fs::read_to_string(&toc)?;
            let content = original
                .split_inclusive('\n')
                .map(|line| {
                    if line.starts_with("## X-Website:") {
                        format!(
                            "## X-Website: {website}{}",
                            if line.ends_with("\r\n") {
                                "\r\n"
                            } else if line.ends_with('\n') {
                                "\n"
                            } else {
                                ""
                            }
                        )
                    } else {
                        line.to_owned()
                    }
                })
                .collect::<String>();
            fs::write(toc, content)?;
        }
        if destination.exists() {
            fs::rename(&destination, &backup)?;
        }
        if let Err(error) = fs::rename(&prepared, &destination) {
            if backup.exists() {
                fs::rename(&backup, &destination)?;
            }
            return Err(error.into());
        }
        if backup.exists() {
            fs::remove_dir_all(backup)?;
        }
        installed.push(destination)
    }
    Ok(installed)
}
pub fn default_state_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| env::current_dir().unwrap_or_default())
        .join(".config/goldbook/state.json")
}

include!(concat!(env!("OUT_DIR"), "/addon.rs"));
pub fn install_bundled_addon(
    wow_dir: Option<&Path>,
    website: Option<&str>,
) -> Result<Vec<PathBuf>> {
    let source = tempfile::tempdir()?;
    for (name, bytes) in BUNDLED_ADDON {
        fs::write(source.path().join(name), bytes)?;
    }
    install_addon(wow_dir, source.path(), website)
}
