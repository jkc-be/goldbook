mod professions;
pub use professions::{profession_items, professions, Profession};

mod sellers;
pub use sellers::{parse_seller_snapshot, SellerOffer, SellerSnapshot, SellerSummary};

mod trades;
pub use trades::{parse_trade, Trade, MAX_TRADES};

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};

pub const MAX_SELLER_BATCH: usize = 100;
pub const MAX_CHARACTERS: usize = 50;
pub const MAX_GOLD_POINTS: usize = 1500;
pub const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
pub type PriceRow = (String, u64, u64, u64, u64);
pub type ItemInfo = (String, u64);
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanUpload {
    pub realm: String,
    pub faction: String,
    pub region: String,
    pub scanned_at: u64,
    pub mode: String,
    pub scanner: String,
    pub build: String,
    pub rows: Vec<PriceRow>,
    pub items: BTreeMap<String, ItemInfo>,
}
impl ScanUpload {
    pub fn fingerprint(&self) -> String {
        let mut rows = self.rows.clone();
        rows.sort();
        sha256(
            serde_json::to_string(&json!([
                self.realm,
                self.faction,
                self.region,
                self.scanned_at,
                self.mode,
                self.scanner,
                self.build,
                rows
            ]))
            .unwrap(),
        )
    }
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountUpload {
    pub id: String,
    pub key_hash: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub previous_key_hash: Option<String>,
    pub characters: Vec<Character>,
    /// Left out when empty, so that an account without trades uploads as before.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub trades: Vec<Trade>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Character {
    pub name: String,
    pub realm: String,
    pub faction: Option<String>,
    pub class: Option<String>,
    pub level: Option<u64>,
    pub updated_at: Option<u64>,
    pub gold: Vec<(u64, u64)>,
    pub bags: Option<Container>,
    pub bank: Option<Container>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Container {
    pub at: Option<u64>,
    pub rows: Vec<ItemRow>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ItemRow {
    pub key: String,
    pub name: Option<String>,
    pub quality: u64,
    pub count: u64,
    pub action: String,
    pub post: Option<u64>,
    pub vendor: u64,
    pub value: u64,
}
pub fn sha256(bytes: impl AsRef<[u8]>) -> String {
    hex::encode(Sha256::digest(bytes.as_ref()))
}
pub fn normalize_code(text: &str) -> String {
    text.to_uppercase()
        .chars()
        .filter_map(|c| {
            let c = match c {
                'O' => '0',
                'I' | 'L' => '1',
                c => c,
            };
            (c.is_ascii_digit() || "ABCDEFGHJKMNPQRSTVWXYZ".contains(c)).then_some(c)
        })
        .collect()
}
pub fn key_hash(key: &str) -> String {
    sha256(normalize_code(key))
}
pub fn valid_item_key(key: &str) -> bool {
    fn digits(s: &str) -> bool {
        !s.is_empty() && s.len() <= 10 && s.bytes().all(|c| c.is_ascii_digit())
    }
    let mut parts = key.split(':');
    let first = parts.next().unwrap_or("");
    digits(first)
        && match parts.next() {
            None => true,
            Some(s) => digits(s.strip_prefix('-').unwrap_or(s)) && parts.next().is_none(),
        }
}
fn object<'a>(v: &'a Value, at: &str) -> Result<&'a Map<String, Value>, String> {
    v.as_object()
        .ok_or_else(|| format!("{at} must be an object"))
}
fn field<'a>(o: &'a Map<String, Value>, key: &str) -> &'a Value {
    o.get(key).unwrap_or(&Value::Null)
}
fn list<'a>(v: &'a Value, at: &str, max: usize) -> Result<&'a Vec<Value>, String> {
    v.as_array()
        .filter(|v| v.len() <= max)
        .ok_or_else(|| format!("{at} must be an array of at most {max} entries"))
}
fn text(v: &Value, at: &str, min: usize, max: usize) -> Result<String, String> {
    v.as_str()
        .filter(|s| (min..=max).contains(&s.encode_utf16().count()))
        .map(str::to_owned)
        .ok_or_else(|| format!("{at} must be a string of {min} to {max} characters"))
}
pub fn integer(v: &Value, min: u64, max: u64) -> Option<u64> {
    v.as_f64()
        .filter(|n| n.is_finite() && n.fract() == 0.0 && *n >= min as f64 && *n <= max as f64)
        .map(|n| n as u64)
}
fn count(v: &Value, at: &str) -> Result<u64, String> {
    integer(v, 0, MAX_SAFE_INTEGER).ok_or_else(|| format!("{at} must be a non-negative integer"))
}
fn nullable_count(v: Option<&Value>, at: &str) -> Result<Option<u64>, String> {
    match v {
        Some(Value::Null) => Ok(None),
        Some(v) => integer(v, 0, MAX_SAFE_INTEGER)
            .map(Some)
            .ok_or_else(|| format!("{at} must be a non-negative integer or null")),
        None => Err(format!("{at} must be a non-negative integer or null")),
    }
}
fn item_key(v: &Value, at: &str) -> Result<String, String> {
    v.as_str()
        .filter(|s| valid_item_key(s))
        .map(str::to_owned)
        .ok_or_else(|| format!("{at} must look like \"2589\" or \"9775:584\""))
}
fn hash(v: &Value, at: &str) -> Result<String, String> {
    v.as_str()
        .filter(|s| {
            s.len() == 64
                && s.bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        })
        .map(str::to_owned)
        .ok_or_else(|| format!("{at} must be 64 lowercase hex characters"))
}
pub fn parse_scan_upload(v: &Value) -> Result<ScanUpload, String> {
    let s = object(v, "scan")?;
    let mode = field(s, "mode")
        .as_str()
        .filter(|s| ["browse", "replicate"].contains(s))
        .ok_or("mode must be one of browse, replicate")?
        .to_owned();
    let mut keys = HashSet::new();
    let mut rows = Vec::new();
    for (i, r) in list(field(s, "rows"), "rows", 200_000)?.iter().enumerate() {
        let at = format!("rows[{i}]");
        let r = r
            .as_array()
            .filter(|r| r.len() == 5)
            .ok_or_else(|| format!("{at} must have 5 fields"))?;
        let key = item_key(&r[0], &format!("{at} item key"))?;
        if !keys.insert(key.clone()) {
            return Err(format!("{at} repeats item key {key}"));
        }
        let min = count(&r[1], &format!("{at} min buyout"))?;
        if min == 0 {
            return Err(format!("{at} min buyout must be positive"));
        }
        rows.push((
            key,
            min,
            count(&r[2], &format!("{at} market value"))?,
            count(&r[3], &format!("{at} quantity"))?,
            count(&r[4], &format!("{at} auction count"))?,
        ));
    }
    let mut items = BTreeMap::new();
    for (key, info) in object(field(s, "items"), "items")? {
        item_key(&Value::String(key.clone()), "items key")?;
        let err = || format!("items[{key}] must be [name, quality]");
        let info = info.as_array().ok_or_else(err)?;
        let name = info
            .first()
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty() && s.encode_utf16().count() <= 200)
            .ok_or_else(err)?
            .to_owned();
        items.insert(
            key.clone(),
            (
                name,
                count(
                    info.get(1).unwrap_or(&Value::Null),
                    &format!("items[{key}] quality"),
                )?,
            ),
        );
    }
    let scanned_at = count(field(s, "scannedAt"), "scannedAt")?;
    if scanned_at == 0 {
        return Err("scannedAt must be a unix timestamp".into());
    }
    Ok(ScanUpload {
        realm: text(field(s, "realm"), "realm", 1, 64)?,
        faction: text(field(s, "faction"), "faction", 1, 64)?,
        region: text(field(s, "region"), "region", 0, 64)?,
        scanned_at,
        mode,
        scanner: text(field(s, "scanner"), "scanner", 0, 64)?,
        build: text(field(s, "build"), "build", 0, 64)?,
        rows,
        items,
    })
}
fn parse_row(v: &Value, at: &str) -> Result<ItemRow, String> {
    let r = object(v, at)?;
    let key = item_key(field(r, "key"), &format!("{at}.key"))?;
    let name =
        match r.get("name") {
            Some(Value::Null) => None,
            Some(v) => Some(text(v, &format!("{at}.name"), 0, 200).map_err(|_| {
                format!("{at}.name must be a string of 0 to 200 characters or null")
            })?),
            None => {
                return Err(format!(
                    "{at}.name must be a string of 0 to 200 characters or null"
                ))
            }
        };
    let quality = integer(field(r, "quality"), 0, 8)
        .ok_or_else(|| format!("{at}.quality must be an integer from 0 to 8"))?;
    let count = integer(field(r, "count"), 1, MAX_SAFE_INTEGER)
        .ok_or_else(|| format!("{at}.count must be a positive integer"))?;
    let action = field(r, "action")
        .as_str()
        .filter(|a| ["auction", "vendor", "unknown"].contains(a))
        .ok_or_else(|| format!("{at}.action must be one of auction, vendor, unknown"))?
        .to_owned();
    Ok(ItemRow {
        key,
        name,
        quality,
        count,
        action,
        post: nullable_count(r.get("post"), &format!("{at}.post"))?,
        vendor: self::count(field(r, "vendor"), &format!("{at}.vendor"))?,
        value: self::count(field(r, "value"), &format!("{at}.value"))?,
    })
}
fn container(v: Option<&Value>, at: &str) -> Result<Option<Container>, String> {
    if v == Some(&Value::Null) {
        return Ok(None);
    }
    let c = v
        .and_then(Value::as_object)
        .ok_or_else(|| format!("{at} must be an object or null"))?;
    let time = nullable_count(c.get("at"), &format!("{at}.at"))?;
    let rows = list(field(c, "rows"), &format!("{at}.rows"), 1000)?
        .iter()
        .enumerate()
        .map(|(i, v)| parse_row(v, &format!("{at}.rows[{i}]")))
        .collect::<Result<_, _>>()?;
    Ok(Some(Container { at: time, rows }))
}
fn character(v: &Value, at: &str) -> Result<Character, String> {
    let c = object(v, at)?;
    let name = text(field(c, "name"), &format!("{at}.name"), 1, 64)?;
    let realm = text(field(c, "realm"), &format!("{at}.realm"), 1, 64)?;
    let faction = match c.get("faction") {
        Some(Value::Null) => None,
        Some(Value::String(s)) if ["Alliance", "Horde", "Neutral"].contains(&s.as_str()) => {
            Some(s.clone())
        }
        _ => {
            return Err(format!(
                "{at}.faction must be one of Alliance, Horde, Neutral or null"
            ))
        }
    };
    let class =
        match c.get("class") {
            Some(Value::Null) => None,
            Some(v) => Some(text(v, &format!("{at}.class"), 1, 20).map_err(|_| {
                format!("{at}.class must be a string of 1 to 20 characters or null")
            })?),
            None => {
                return Err(format!(
                    "{at}.class must be a string of 1 to 20 characters or null"
                ))
            }
        };
    let level = match c.get("level") {
        Some(Value::Null) => None,
        Some(v) => Some(
            integer(v, 1, 100)
                .ok_or_else(|| format!("{at}.level must be an integer from 1 to 100 or null"))?,
        ),
        None => {
            return Err(format!(
                "{at}.level must be an integer from 1 to 100 or null"
            ))
        }
    };
    let updated_at = nullable_count(c.get("updatedAt"), &format!("{at}.updatedAt"))?;
    let mut gold = Vec::new();
    for (i, e) in list(field(c, "gold"), &format!("{at}.gold"), MAX_GOLD_POINTS)?
        .iter()
        .enumerate()
    {
        let pair=e.as_array().filter(|e|e.len()==2).and_then(|e|Some((integer(&e[0],1_000_000_000,MAX_SAFE_INTEGER)?,integer(&e[1],0,MAX_SAFE_INTEGER)?))).filter(|p|p.0%3600==0).ok_or_else(||format!("{at}.gold[{i}] must be [time, copper]: a unix time on the hour and a non-negative integer"))?;
        gold.push(pair);
    }
    Ok(Character {
        name,
        realm,
        faction,
        class,
        level,
        updated_at,
        gold,
        bags: container(c.get("bags"), &format!("{at}.bags"))?,
        bank: container(c.get("bank"), &format!("{at}.bank"))?,
    })
}
pub fn parse_account_upload(v: &Value) -> Result<AccountUpload, String> {
    let a = object(v, "account")?;
    let id = field(a, "id")
        .as_str()
        .filter(|s| s.len() == 8 && normalize_code(s) == *s)
        .ok_or("id must be 8 characters of the login code alphabet")?
        .to_owned();
    let key_hash = hash(field(a, "keyHash"), "keyHash")?;
    let previous_key_hash = a
        .get("previousKeyHash")
        .map(|v| hash(v, "previousKeyHash"))
        .transpose()?;
    let characters = list(field(a, "characters"), "characters", MAX_CHARACTERS)?
        .iter()
        .enumerate()
        .map(|(i, v)| character(v, &format!("characters[{i}]")))
        .collect::<Result<_, _>>()?;
    let trades = match a.get("trades") {
        None => Vec::new(),
        Some(v) => list(v, "trades", MAX_TRADES)?
            .iter()
            .enumerate()
            .map(|(i, v)| parse_trade(v, &format!("trades[{i}]")))
            .collect::<Result<_, _>>()?,
    };
    Ok(AccountUpload {
        id,
        key_hash,
        previous_key_hash,
        characters,
        trades,
    })
}

#[cfg(test)]
mod tests;
