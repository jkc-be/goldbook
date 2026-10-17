use crate::{
    api_url,
    paths::{flavor_saved_variables, SERVER_DATA},
    read_saved_variables,
    sync::file_lock,
    Logger, SavedVariables,
};
use anyhow::{anyhow, bail, Result};
use serde::Deserialize;
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt::Write as _,
    fs,
    io::Write as _,
    path::{Path, PathBuf},
    time::Duration,
};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Export {
    scanned_at: u64,
    items: BTreeMap<String, ExportItem>,
}
#[derive(Debug, Deserialize)]
struct ExportItem {
    name: Option<String>,
    quality: Option<u64>,
    price: [u64; 6],
    #[serde(default)]
    hours: Vec<[u64; 4]>,
    #[serde(default)]
    days: Vec<[u64; 4]>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerData {
    NoAddon,
    NoRealms,
    Unchanged {
        realms: Vec<String>,
    },
    Written {
        realms: Vec<String>,
        items: usize,
        path: PathBuf,
    },
}

// LuaJIT allows 65,536 constants in one function, so the file fills each table
// in functions that hold at most this many entries.
const CHUNK: usize = 10_000;
const HEADER: &str = "-- The Goldbook app writes this file with prices from the Goldbook server.\n-- The app rewrites it, so edits to it are lost.\n";

// Decimal escapes have three digits, so a digit after one cannot join it.
fn lua_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => {
                let _ = write!(out, "\\{:03}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
fn fill(out: &mut String, table: &str, entries: &[(&str, String)]) {
    for chunk in entries.chunks(CHUNK) {
        let _ = writeln!(out, "fill({table}, function(t)");
        for (key, value) in chunk {
            let _ = writeln!(out, "t[{}] = {}", lua_string(key), lua_string(value));
        }
        out.push_str("end)\n");
    }
}
fn history(entries: &[[u64; 4]]) -> String {
    entries
        .iter()
        .map(|[at, min, qty, mv]| format!("{at}:{min}:{qty}:{mv}"))
        .collect::<Vec<_>>()
        .join(",")
}
fn render(server: &str, realms: &BTreeMap<String, Export>) -> String {
    let mut out = String::from(HEADER);
    let _ = writeln!(
        out,
        "local data = {{ version = 1, server = {}, items = {{}}, realms = {{}} }}",
        lua_string(server)
    );
    out.push_str("local function fill(t, f) f(t) end\n");
    let mut items = BTreeMap::new();
    for export in realms.values() {
        for (key, item) in &export.items {
            if let (Some(name), Some(quality)) = (&item.name, item.quality) {
                items
                    .entry(key.as_str())
                    .or_insert_with(|| format!("{quality}|{name}"));
            }
        }
    }
    fill(
        &mut out,
        "data.items",
        &items.into_iter().collect::<Vec<_>>(),
    );
    for (realm_key, export) in realms {
        let realm = format!("data.realms[{}]", lua_string(realm_key));
        let _ = writeln!(
            out,
            "{realm} = {{ scannedAt = {}, prices = {{}}, hours = {{}}, days = {{}} }}",
            export.scanned_at
        );
        let (mut prices, mut hours, mut days) = (Vec::new(), Vec::new(), Vec::new());
        for (key, item) in &export.items {
            prices.push((key.as_str(), item.price.map(|n| n.to_string()).join(",")));
            if !item.hours.is_empty() {
                hours.push((key.as_str(), history(&item.hours)));
            }
            if !item.days.is_empty() {
                days.push((key.as_str(), history(&item.days)));
            }
        }
        for (table, entries) in [("prices", prices), ("hours", hours), ("days", days)] {
            fill(&mut out, &format!("{realm}.{table}"), &entries);
        }
    }
    out.push_str("GoldbookServerData = data\n");
    out
}

fn realm_keys(saved: &SavedVariables) -> BTreeSet<String> {
    let mut keys = BTreeSet::new();
    let Some(db) = saved.get("GoldbookDB").and_then(Value::as_object) else {
        return keys;
    };
    for table in ["prices", "scanned"] {
        if let Some(table) = db.get(table).and_then(Value::as_object) {
            keys.extend(table.keys().cloned())
        }
    }
    if let Some(characters) = db.get("characters").and_then(Value::as_object) {
        for character in characters.values() {
            let field = |name| character.get(name).and_then(Value::as_str);
            if let (Some(realm), Some(faction)) = (field("realm"), field("faction")) {
                keys.insert(format!("{realm}-{faction}"));
            }
        }
    }
    keys
}
// Realm names contain hyphens, faction names do not.
fn split_realm_key(key: &str) -> Option<(&str, &str)> {
    key.rsplit_once('-')
        .filter(|(realm, faction)| !realm.is_empty() && !faction.is_empty())
}

pub async fn write_server_data(flavor: &Path, api: &str, log: &Logger) -> Result<ServerData> {
    let result = refresh(flavor, api, log).await;
    if let Err(e) = &result {
        log(&format!(
            "server prices for {} failed: {e}",
            flavor.display()
        ));
    }
    result
}
async fn refresh(flavor: &Path, api: &str, log: &Logger) -> Result<ServerData> {
    let addon = flavor.join("Interface/AddOns/Goldbook");
    if !addon.is_dir() {
        return Ok(ServerData::NoAddon);
    }
    // Keyed by the canonical folder, so the key is the same before and after the file exists.
    let lock = file_lock(&fs::canonicalize(&addon)?.join(SERVER_DATA));
    let _guard = lock.lock().await;
    let mut keys = BTreeSet::new();
    for file in flavor_saved_variables(flavor) {
        if !file.is_file() {
            continue;
        }
        match read_saved_variables(&file) {
            Ok(saved) => keys.extend(realm_keys(&saved)),
            Err(e) => log(&format!("{}: {e}", file.display())),
        }
    }
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()?;
    let url = api_url(api, "api/export")?;
    let mut realms = BTreeMap::new();
    for key in keys {
        let Some((realm, faction)) = split_realm_key(&key) else {
            continue;
        };
        let response = client
            .get(url.clone())
            .query(&[("realm", realm), ("faction", faction)])
            .send()
            .await
            .map_err(|e| anyhow!("export of {key}: {e}"))?;
        let status = response.status();
        if status == reqwest::StatusCode::NOT_FOUND {
            continue;
        }
        if !status.is_success() {
            let text = response.text().await.unwrap_or_default();
            bail!("export of {key} answered {} {text}", status.as_u16());
        }
        let body = response
            .bytes()
            .await
            .map_err(|e| anyhow!("export of {key}: {e}"))?;
        let export =
            serde_json::from_slice::<Export>(&body).map_err(|e| anyhow!("export of {key}: {e}"))?;
        realms.insert(key, export);
    }
    if realms.is_empty() {
        return Ok(ServerData::NoRealms);
    }
    let content = render(api, &realms);
    let path = addon.join(SERVER_DATA);
    let names = realms.keys().cloned().collect::<Vec<_>>();
    if fs::read(&path).is_ok_and(|old| old == content.as_bytes()) {
        log(&format!(
            "server prices for {} unchanged in {}",
            names.join(", "),
            path.display()
        ));
        return Ok(ServerData::Unchanged { realms: names });
    }
    let mut temp = tempfile::NamedTempFile::new_in(&addon)?;
    temp.write_all(content.as_bytes())?;
    temp.flush()?;
    temp.as_file().sync_all()?;
    temp.persist(&path).map_err(|e| e.error)?;
    let items = realms.values().map(|export| export.items.len()).sum();
    log(&format!(
        "server prices for {} written to {}: {items} items",
        names.join(", "),
        path.display()
    ));
    Ok(ServerData::Written {
        realms: names,
        items,
        path,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(name: Option<&str>, hours: Vec<[u64; 4]>) -> ExportItem {
        ExportItem {
            name: name.map(str::to_owned),
            quality: name.map(|_| 1),
            price: [100, 100, 4, 1760090000, 105, 1760090000],
            hours,
            days: vec![[20371, 100, 100, 105]],
        }
    }

    #[test]
    fn lua_strings_escape_quotes_backslashes_and_control_bytes() {
        assert_eq!(lua_string("Linen Cloth"), r#""Linen Cloth""#);
        assert_eq!(
            lua_string("Thrall's \"Best\" \\ Wool\nnext\u{1}2\u{7f}"),
            r#""Thrall's \"Best\" \\ Wool\010next\0012\127""#
        );
        assert_eq!(lua_string("Ünïcode 魔法"), "\"Ünïcode 魔法\"");
        assert_eq!(lua_string("\0"), r#""\000""#);
    }

    #[test]
    fn render_writes_sorted_escaped_tables_without_missing_names_or_hours() {
        let mut realms = BTreeMap::new();
        realms.insert(
            "Faramon-Horde".to_owned(),
            Export {
                scanned_at: 1760090000,
                items: BTreeMap::from([
                    (
                        "2589".to_owned(),
                        item(
                            Some("Linen Cloth"),
                            vec![[488912, 110, 42, 0], [488913, 100, 100, 105]],
                        ),
                    ),
                    (
                        "2592".to_owned(),
                        item(Some("Wool \"Fine\"\n\u{1}9"), vec![]),
                    ),
                    ("9775:584".to_owned(), item(None, vec![[488913, 7, 1, 0]])),
                ]),
            },
        );
        realms.insert(
            "Area 52-Alliance".to_owned(),
            Export {
                scanned_at: 1760000000,
                items: BTreeMap::from([("2589".to_owned(), item(Some("Other name"), vec![]))]),
            },
        );
        assert_eq!(
            render("https://app.example/\"goldbook\"", &realms),
            r#"-- The Goldbook app writes this file with prices from the Goldbook server.
-- The app rewrites it, so edits to it are lost.
local data = { version = 1, server = "https://app.example/\"goldbook\"", items = {}, realms = {} }
local function fill(t, f) f(t) end
fill(data.items, function(t)
t["2589"] = "1|Other name"
t["2592"] = "1|Wool \"Fine\"\010\0019"
end)
data.realms["Area 52-Alliance"] = { scannedAt = 1760000000, prices = {}, hours = {}, days = {} }
fill(data.realms["Area 52-Alliance"].prices, function(t)
t["2589"] = "100,100,4,1760090000,105,1760090000"
end)
fill(data.realms["Area 52-Alliance"].days, function(t)
t["2589"] = "20371:100:100:105"
end)
data.realms["Faramon-Horde"] = { scannedAt = 1760090000, prices = {}, hours = {}, days = {} }
fill(data.realms["Faramon-Horde"].prices, function(t)
t["2589"] = "100,100,4,1760090000,105,1760090000"
t["2592"] = "100,100,4,1760090000,105,1760090000"
t["9775:584"] = "100,100,4,1760090000,105,1760090000"
end)
fill(data.realms["Faramon-Horde"].hours, function(t)
t["2589"] = "488912:110:42:0,488913:100:100:105"
t["9775:584"] = "488913:7:1:0"
end)
fill(data.realms["Faramon-Horde"].days, function(t)
t["2589"] = "20371:100:100:105"
t["2592"] = "20371:100:100:105"
t["9775:584"] = "20371:100:100:105"
end)
GoldbookServerData = data
"#
        );
    }

    #[test]
    fn render_fills_tables_in_functions_of_at_most_10000_entries() {
        let items = (0..20_001)
            .map(|i| (format!("{i:05}"), item(Some("Linen Cloth"), vec![])))
            .collect();
        let realms = BTreeMap::from([(
            "Faramon-Horde".to_owned(),
            Export {
                scanned_at: 1,
                items,
            },
        )]);
        let file = render("https://app.example", &realms);
        let blocks = file
            .split("fill(data.items, function(t)\n")
            .skip(1)
            .map(|block| block.split("end)\n").next().unwrap().lines().count())
            .collect::<Vec<_>>();
        assert_eq!(blocks, vec![10_000, 10_000, 1]);
        assert!(file.contains(
            "t[\"09999\"] = \"1|Linen Cloth\"\nend)\nfill(data.items, function(t)\nt[\"10000\"]"
        ));
        assert_eq!(
            file.matches("fill(data.realms[\"Faramon-Horde\"].prices, function(t)")
                .count(),
            3
        );
    }

    #[test]
    fn realm_keys_come_from_prices_scans_and_characters() {
        let saved = crate::parse_saved_variables(
            r#"GoldbookDB = {
["prices"] = { ["Faramon-Horde"] = { ["2589"] = "1,1,1,1,1,1;;" } },
["scanned"] = { ["Area 52-Alliance"] = 1760000000, ["Faramon-Horde"] = 1760090000 },
["characters"] = {
  ["Sultan-Pyrewood Village"] = { ["realm"] = "Pyrewood Village", ["faction"] = "Alliance" },
  ["Nameless-Faramon"] = { ["realm"] = "Faramon" },
},
}"#,
        )
        .unwrap();
        assert_eq!(
            realm_keys(&saved).into_iter().collect::<Vec<_>>(),
            vec![
                "Area 52-Alliance",
                "Faramon-Horde",
                "Pyrewood Village-Alliance"
            ]
        );
        assert_eq!(
            split_realm_key("Azjol-Nerub-Horde"),
            Some(("Azjol-Nerub", "Horde"))
        );
        assert_eq!(split_realm_key("Faramon"), None);
        assert_eq!(split_realm_key("-Horde"), None);
    }
}
