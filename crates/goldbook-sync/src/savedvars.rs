use crate::luatable::{js_value, SavedVariables};
use anyhow::{anyhow, bail, Result};
use goldbook_core::{
    key_hash, normalize_code, parse_account_upload, parse_scan_upload, parse_trade, sha256,
    AccountUpload, ScanUpload, Trade, MAX_CHARACTERS, MAX_GOLD_POINTS, MAX_TRADES,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};

fn table<'a>(v: Option<&'a Value>, what: &str) -> Result<&'a Map<String, Value>> {
    static EMPTY: std::sync::LazyLock<Map<String, Value>> = std::sync::LazyLock::new(Map::new);
    match v {
        Some(Value::Object(m)) => Ok(m),
        Some(Value::Array(a)) if a.is_empty() => Ok(&EMPTY),
        _ => bail!("{what} is not a table"),
    }
}
fn list<'a>(v: Option<&'a Value>, what: &str) -> Result<&'a Vec<Value>> {
    v.and_then(Value::as_array)
        .ok_or_else(|| anyhow!("{what} is not a list"))
}
fn get(m: &Map<String, Value>, k: &str) -> Value {
    m.get(k).cloned().unwrap_or(Value::Null)
}
fn shown(v: Option<&Value>) -> String {
    match v {
        None => "undefined".into(),
        Some(Value::String(s)) => s.clone(),
        Some(v) => v.to_string(),
    }
}
fn js_number(s: &str) -> Value {
    let s = s.trim();
    if s.is_empty() {
        return json!(0);
    }
    let n = if let Some(s) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        u64::from_str_radix(s, 16).ok().map(|n| n as f64)
    } else {
        s.parse::<f64>().ok()
    };
    match n {
        Some(n) if n.is_finite() && n.fract() == 0.0 && n >= 0.0 && n <= u64::MAX as f64 => {
            json!(n as u64)
        }
        Some(n) if n.is_finite() => json!(n),
        _ => json!({"$goldbookNonFinite":"nan"}),
    }
}
#[derive(Debug, Clone)]
pub struct QueuedScan {
    pub id: String,
    pub label: String,
    entry: Value,
    names: Map<String, Value>,
    what: String,
}
impl QueuedScan {
    pub fn decode(&self) -> Result<ScanUpload> {
        let s = table(Some(&self.entry), &self.what)?;
        let data = s
            .get("data")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("{} has no data", self.what))?;
        let mut rows = Vec::new();
        if !data.is_empty() {
            for part in data.split(';') {
                let fields = part.split(',').collect::<Vec<_>>();
                if fields.len() != 5 {
                    bail!("{} has a malformed row \"{part}\"", self.what)
                }
                let mut row = vec![json!(fields[0])];
                row.extend(fields[1..].iter().map(|s| js_number(s)));
                rows.push(Value::Array(row));
            }
        }
        if s.get("count").and_then(Value::as_f64) != Some(rows.len() as f64) {
            bail!(
                "{} holds {} rows but declares {}",
                self.what,
                rows.len(),
                shown(s.get("count"))
            )
        }
        let mut items = Map::new();
        for row in &rows {
            let key = row[0].as_str().unwrap();
            if let Some(packed) = self.names.get(key).and_then(Value::as_str) {
                if let Some((quality, name)) = packed.split_once('|') {
                    if !name.is_empty() {
                        items.insert(key.to_owned(), json!([name, js_number(quality)]));
                    }
                }
            }
        }
        parse_scan_upload(&json!({"realm":get(s,"realm"),"faction":get(s,"faction"),"region":get(s,"region"),"scannedAt":get(s,"at"),"mode":get(s,"mode"),"scanner":get(s,"by"),"build":get(s,"build"),"rows":rows,"items":items})).map_err(anyhow::Error::msg)
    }
}
pub fn extract_scans(saved: &SavedVariables) -> Result<Vec<QueuedScan>> {
    let db = table(saved.get("GoldbookDB"), "GoldbookDB")?;
    let names = table(db.get("items"), "GoldbookDB.items")?;
    list(db.get("scans"), "GoldbookDB.scans")?
        .iter()
        .enumerate()
        .map(|(i, entry)| {
            let what = format!("GoldbookDB.scans[{}]", i + 1);
            let (label, identity) = match entry.as_object() {
                Some(m) => (
                    format!(
                        "{}|{}|{}",
                        shown(m.get("realm")),
                        shown(m.get("faction")),
                        shown(m.get("at"))
                    ),
                    serde_json::to_string(&js_value(&Value::Array(
                        [
                            "realm", "faction", "region", "at", "mode", "by", "build", "data",
                        ]
                        .map(|k| get(m, k))
                        .to_vec(),
                    )))?,
                ),
                None => (what.clone(), what.clone()),
            };
            Ok(QueuedScan {
                id: format!("scan:{}", sha256(identity)),
                label,
                entry: entry.clone(),
                names: names.clone(),
                what,
            })
        })
        .collect()
}
#[derive(Debug, Clone)]
pub struct QueuedSellerSnapshot {
    pub id: String,
    payload: Value,
}
impl QueuedSellerSnapshot {
    pub fn decode(&self) -> Result<goldbook_core::SellerSnapshot> {
        goldbook_core::parse_seller_snapshot(&self.payload).map_err(anyhow::Error::msg)
    }
}
pub fn extract_seller_snapshots(saved: &SavedVariables) -> Result<Vec<QueuedSellerSnapshot>> {
    let db = table(saved.get("GoldbookDB"), "GoldbookDB")?;
    let Some(snapshots) = db.get("sellerScans") else {
        return Ok(Vec::new());
    };
    table(Some(snapshots), "GoldbookDB.sellerScans")?
        .values()
        .map(|snapshot| {
            let payload = snapshot.clone();
            Ok(QueuedSellerSnapshot {
                id: format!("sellers:{}", sha256(serde_json::to_vec(&payload)?)),
                payload,
            })
        })
        .collect()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebLogin {
    pub id: String,
    pub key: String,
}
pub fn extract_login(saved: &SavedVariables) -> Result<Option<WebLogin>> {
    let db = table(saved.get("GoldbookDB"), "GoldbookDB")?;
    let Some(v) = db.get("account") else {
        return Ok(None);
    };
    let a = table(Some(v), "GoldbookDB.account")?;
    let key = a
        .get("key")
        .and_then(Value::as_str)
        .filter(|s| s.len() == 20 && normalize_code(s) == *s)
        .ok_or_else(|| {
            anyhow!("GoldbookDB.account.key must be 20 characters of the login code alphabet")
        })?;
    let id = a
        .get("id")
        .and_then(Value::as_str)
        .filter(|s| s.len() == 8 && normalize_code(s) == *s)
        .ok_or_else(|| anyhow!("id must be 8 characters of the login code alphabet"))?;
    Ok(Some(WebLogin {
        id: id.into(),
        key: key.into(),
    }))
}
fn container(v: Option<&Value>, what: &str) -> Result<Value> {
    let Some(v) = v else { return Ok(Value::Null) };
    let c = table(Some(v), what)?;
    let rows=list(c.get("rows"),&format!("{what}.rows"))?.iter().enumerate().map(|(i,row)|{let r=table(Some(row),&format!("{what}.rows[{}]",i+1))?;Ok(json!({"key":get(r,"key"),"name":get(r,"name"),"quality":get(r,"quality"),"count":get(r,"count"),"action":get(r,"action"),"post":get(r,"post"),"vendor":get(r,"vendor"),"value":get(r,"value")}))}).collect::<Result<Vec<_>>>()?;
    Ok(json!({"at":get(c,"at"),"rows":rows}))
}
pub(crate) fn normalized_realm(realm: &str) -> String {
    realm
        .chars()
        .filter(|c| !(c.is_whitespace() && *c != '\u{0085}' || *c == '\u{feff}'))
        .collect()
}

fn newer_container(first: Value, second: &Value) -> Value {
    if first.is_null() {
        return second.clone();
    }
    if second.is_null() {
        return first;
    }
    if second["at"].as_f64().unwrap_or(0.0) >= first["at"].as_f64().unwrap_or(0.0) {
        second.clone()
    } else {
        first
    }
}

fn merge_characters(characters: Vec<(String, u64, Value)>) -> Vec<(String, u64, Value)> {
    let mut groups: BTreeMap<String, Vec<(String, u64, Value)>> = BTreeMap::new();
    for entry in characters {
        let name = entry
            .0
            .split_once('-')
            .map(|(name, realm)| format!("{name}-{}", normalized_realm(realm)))
            .unwrap_or_else(|| entry.0.clone());
        groups.entry(name).or_default().push(entry);
    }
    groups
        .into_iter()
        .map(|(name, mut group)| {
            group.sort_by(|a, b| {
                a.2["updatedAt"]
                    .as_f64()
                    .unwrap_or(0.0)
                    .total_cmp(&b.2["updatedAt"].as_f64().unwrap_or(0.0))
                    .then((a.0 == name).cmp(&(b.0 == name)))
            });
            let mut latest = group[0].2.clone();
            let mut bags = Value::Null;
            let mut bank = Value::Null;
            let mut gold = BTreeMap::new();
            for (_, _, character) in group {
                bags = newer_container(bags, &character["bags"]);
                bank = newer_container(bank, &character["bank"]);
                for point in character["gold"]
                    .as_array()
                    .expect("decoded gold is an array")
                {
                    gold.insert(point[0].to_string(), point.clone());
                }
                latest = character;
            }
            let mut points = gold.into_values().collect::<Vec<_>>();
            points.sort_by(|a, b| {
                a[0].as_f64()
                    .unwrap_or(0.0)
                    .total_cmp(&b[0].as_f64().unwrap_or(0.0))
            });
            let points = points.split_off(points.len().saturating_sub(MAX_GOLD_POINTS));
            let seen = latest["updatedAt"]
                .as_u64()
                .unwrap_or(0)
                .max(points.last().and_then(|p| p[0].as_u64()).unwrap_or(0));
            if let Some(realm) = latest["realm"].as_str() {
                latest["realm"] = json!(normalized_realm(realm));
            }
            latest["gold"] = json!(points);
            latest["bags"] = bags;
            latest["bank"] = bank;
            (name, seen, latest)
        })
        .collect()
}

/// The trades booked under GoldbookDB.trades["Name-Realm"], the newest
/// MAX_TRADES of them. One the server would refuse is left out rather than
/// hold up the rest of the account.
fn extract_trades(db: &Map<String, Value>) -> Vec<Trade> {
    let Some(Value::Object(booked)) = db.get("trades") else {
        return Vec::new();
    };
    let mut trades = Vec::new();
    for (character, entries) in booked {
        let Some((name, realm)) = character.split_once('-') else {
            continue;
        };
        let entries: Vec<&Value> = match entries {
            Value::Array(entries) => entries.iter().collect(),
            Value::Object(entries) => entries.values().collect(),
            _ => continue,
        };
        for entry in entries {
            let Some(t) = entry.as_object() else {
                continue;
            };
            let trade = json!({"name":name,"realm":normalized_realm(realm),"at":get(t,"at"),"side":get(t,"side"),"item":get(t,"item"),"itemKey":get(t,"key"),"count":get(t,"count"),"price":get(t,"price"),"fee":get(t,"fee")});
            if let Ok(trade) = parse_trade(&trade, "trade") {
                trades.push(trade);
            }
        }
    }
    trades.sort_by(|a, b| b.at.cmp(&a.at).then_with(|| a.cmp(b)));
    trades.truncate(MAX_TRADES);
    trades.sort();
    trades
}

pub fn extract_account(saved: &SavedVariables) -> Result<Option<AccountUpload>> {
    let Some(login) = extract_login(saved)? else {
        return Ok(None);
    };
    let db = table(saved.get("GoldbookDB"), "GoldbookDB")?;
    let empty = json!([]);
    let gold = table(Some(db.get("gold").unwrap_or(&empty)), "GoldbookDB.gold")?;
    let snapshots = table(
        Some(db.get("characters").unwrap_or(&empty)),
        "GoldbookDB.characters",
    )?;
    let mut characters = Vec::new();
    for name in gold.keys().chain(snapshots.keys()).collect::<BTreeSet<_>>() {
        let hours = table(
            Some(gold.get(name).unwrap_or(&empty)),
            &format!("GoldbookDB.gold[{}]", json!(name)),
        )?;
        let mut points = hours
            .iter()
            .map(|(k, v)| {
                let hour = k.parse::<f64>().unwrap_or(f64::NAN) * 3600.0;
                (
                    if hour.is_finite() && hour.fract() == 0.0 && hour >= 0.0 {
                        json!(hour as u64)
                    } else {
                        json!({"$goldbookNonFinite":"nan"})
                    },
                    v.clone(),
                )
            })
            .collect::<Vec<_>>();
        points.sort_by(|a, b| {
            a.0.as_f64()
                .unwrap_or(0.)
                .total_cmp(&b.0.as_f64().unwrap_or(0.))
        });
        let latest_gold = points.last().and_then(|p| p.0.as_u64()).unwrap_or(0);
        let character = if let Some(snapshot) = snapshots.get(name) {
            let what = format!("GoldbookDB.characters[{}]", json!(name));
            let s = table(Some(snapshot), &what)?;
            json!({"name":get(s,"name"),"realm":get(s,"realm"),"faction":get(s,"faction"),"class":get(s,"class"),"level":get(s,"level"),"updatedAt":get(s,"at"),"gold":points,"bags":container(s.get("bags"),&format!("{what}.bags"))?,"bank":container(s.get("bank"),&format!("{what}.bank"))?})
        } else {
            let (n, r) = name.split_once('-').unwrap_or((name, ""));
            json!({"name":n,"realm":r,"faction":null,"class":null,"level":null,"updatedAt":null,"gold":points,"bags":null,"bank":null})
        };
        let latest = latest_gold.max(character["updatedAt"].as_u64().unwrap_or(0));
        characters.push((name.clone(), latest, character));
    }
    let mut characters = merge_characters(characters);
    characters.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    characters.truncate(MAX_CHARACTERS);
    characters.sort_by(|a, b| a.0.cmp(&b.0));
    parse_account_upload(&json!({"id":login.id,"keyHash":key_hash(&login.key),"characters":characters.into_iter().map(|c|c.2).collect::<Vec<_>>(),"trades":extract_trades(db)})).map(Some).map_err(anyhow::Error::msg)
}
