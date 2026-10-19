use crate::{App, Error, Input, Reply, Result, SESSION_SECONDS, db, hash, header, now};
use axum::http::Method;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use flate2::{Compression, write::GzEncoder};
use goldbook_core::{HISTORY_DAYS, PriceRecord};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    io::Write,
    path::Path,
    sync::LazyLock,
};
use subtle::ConstantTimeEq;

const SCANS: &str = "SELECT id, scanned_at AS scannedAt, mode, item_count AS itemCount, scanner FROM scans WHERE realm=?1 AND faction=?2";
const NAMED: &str = "LEFT JOIN items i ON i.item_key=p.item_key";
const MARKET_JOIN: &str = "LEFT JOIN prices m ON m.scan_id=?5 AND m.item_key=p.item_key";
const MARKET: &str = "COALESCE(m.market_value,p.market_value)";
const CHARACTER_COLUMNS: &str = "name, realm, faction, class, level, updated_at AS updatedAt";
// The IDs linked with ?1, the ID their group is kept under.
const GROUP: &str = "SELECT id FROM accounts WHERE COALESCE(owner_id,id)=?1";

pub(super) fn respond(input: Input, app: &App) -> Result<Reply> {
    if input.path.starts_with("/api/auth/battlenet/") {
        return crate::oauth::respond(&input, app);
    }
    let route = (input.method.as_str(), input.path.as_str());
    if !matches!(
        route,
        (
            "POST",
            "/api/scans"
                | "/api/sellers/batch"
                | "/api/sellers"
                | "/api/account"
                | "/api/login"
                | "/api/desktop-login"
                | "/api/logout"
                | "/api/link"
                | "/api/installations"
        ) | (
            "GET",
            "/api/realms"
                | "/api/professions"
                | "/api/sellers"
                | "/api/prices"
                | "/api/deals"
                | "/api/movers"
                | "/api/history"
                | "/api/trends"
                | "/api/export"
                | "/api/account"
                | "/api/character"
                | "/api/trades"
        )
    ) {
        if (input.method == Method::GET || input.method == Method::HEAD)
            && let Some(reply) = static_file(app.config.web_dir.as_deref(), &input.path)
        {
            return Ok(reply);
        }
        return Err(Error::new(404, "not found"));
    }
    let mut db = db::connect(&app.config.database)?;
    match route {
        ("POST", "/api/installations") => register_installation(&input, app, &mut db),
        ("POST", "/api/scans") => upload_scan(&input, &mut db),
        ("POST", "/api/sellers") => upload_sellers(&input, &mut db),
        ("POST", "/api/sellers/batch") => upload_seller_batch(&input, &mut db),
        ("GET", "/api/sellers") => sellers(&input, &db),
        ("POST", "/api/account") => upload_account(&input, &mut db),
        ("POST", "/api/login") => authenticate(&input, app, &mut db, input.json()?, None),
        ("POST", "/api/desktop-login") => {
            let body = std::str::from_utf8(&input.body)
                .map_err(|_| Error::new(400, "invalid desktop login"))?;
            if body.split('&').any(|p| !p.contains('=')) {
                return Err(Error::new(400, "invalid desktop login"));
            }
            let fields: Vec<_> = url::form_urlencoded::parse(body.as_bytes()).collect();
            if fields.len() != 2
                || !fields.iter().any(|(k, _)| k == "id")
                || !fields.iter().any(|(k, _)| k == "key")
            {
                return Err(Error::new(400, "invalid desktop login"));
            }
            let body: serde_json::Map<String, Value> = fields
                .into_iter()
                .map(|(k, v)| (k.into_owned(), Value::String(v.into_owned())))
                .collect();
            // The app names the website's view to open in the query; the
            // website has views of a few lowercase letters. Without one, as
            // from an app before 0.2.4, #characters, which the website now
            // sends on to Gold.
            let view = input
                .query
                .get("view")
                .map(String::as_str)
                .filter(|view| {
                    (1..=32).contains(&view.len()) && view.bytes().all(|b| b.is_ascii_lowercase())
                })
                .unwrap_or("characters");
            authenticate(&input, app, &mut db, Value::Object(body), Some(view))
        }
        ("POST", "/api/link") => link(&input, app, &mut db),
        ("POST", "/api/logout") => {
            db.execute(
                "DELETE FROM sessions WHERE token_hash=?1",
                [hash(input.cookie())],
            )?;
            let mut r = Reply::json(json!({}));
            r.headers.push(cookie(&input, "", 0));
            Ok(r)
        }
        ("GET", "/api/realms") => Ok(Reply::json(
            json!({"realms":db::query(&db,"SELECT realm,faction,MAX(region) AS region,COUNT(*) AS scans,MAX(scanned_at) AS lastScan FROM scans GROUP BY realm,faction ORDER BY lastScan DESC",&[])?}),
        )),
        ("GET", "/api/professions") => Ok(Reply::json(
            json!({"professions": goldbook_core::professions()}),
        )),
        ("GET", "/api/prices") => prices(&input, &db),
        ("GET", "/api/deals") => deals(&input, &db),
        ("GET", "/api/movers") => movers(&input, &db),
        ("GET", "/api/history") => history(&input, &db),
        ("GET", "/api/trends") => trends(&input, &db),
        ("GET", "/api/export") => export(&input, &db),
        ("GET", "/api/account") => characters(&input, &db),
        ("GET", "/api/character") => character(&input, &db),
        ("GET", "/api/trades") => trades(&input, &db),
        _ => unreachable!(),
    }
}
fn required<'a>(input: &'a Input, name: &str) -> Result<&'a str> {
    input
        .query
        .get(name)
        .map(String::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| Error::new(400, format!("{name} is required")))
}
fn integer(input: &Input, name: &str, fallback: i64, maximum: i64) -> Result<i64> {
    let Some(value) = input.query.get(name) else {
        return Ok(fallback);
    };
    let value = value.trim();
    if value.is_empty() {
        return Ok(0);
    }
    if value.bytes().all(|b| b.is_ascii_digit()) {
        // JavaScript and the old API read this through a double first.
        if let Ok(n) = value.parse::<f64>()
            && n <= maximum as f64
        {
            return Ok(n as i64);
        }
    }
    Err(Error::new(
        400,
        format!("{name} must be an integer from 0 to {maximum}"),
    ))
}
fn register_installation(input: &Input, app: &App, db: &mut Connection) -> Result<Reply> {
    if !app.config.self_registration {
        return Err(Error::new(403, "installation registration is disabled"));
    }
    let wait = app.registrations.lock().unwrap().begin(
        None,
        Some(input.client.as_deref().unwrap_or("unknown")),
        now(),
    );
    if wait > 0 {
        return Err(Error::new(429, "too many registrations, try again later"));
    }
    let body = input.json()?;
    let fingerprint = body["fingerprint"].as_str().unwrap_or_default();
    if body.as_object().is_none_or(|object| object.len() != 2)
        || body["fingerprintVersion"].as_u64() != Some(1)
        || fingerprint.len() != 64
        || !fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(Error::new(
            400,
            "provide a version 1 account fingerprint as 64 lowercase hexadecimal characters",
        ));
    }
    let token = format!("gb_{}", URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>()));
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let identity = crate::oauth::enrollment_identity(input, app, &tx)?;
    tx.execute(
        "INSERT INTO upload_identities (fingerprint) VALUES (?1) ON CONFLICT(fingerprint) DO NOTHING",
        [fingerprint],
    )?;
    let blocked: bool = tx.query_row(
        "SELECT blocked_at IS NOT NULL FROM upload_identities WHERE fingerprint=?1",
        [fingerprint],
        |row| row.get(0),
    )?;
    if blocked {
        return Err(Error::new(403, "this account is blocked"));
    }
    if let Some(identity) = identity {
        let existing: Option<String> = tx.query_row(
            "SELECT battlenet_identity FROM upload_identities WHERE fingerprint=?1",
            [fingerprint],
            |row| row.get(0),
        )?;
        if existing
            .as_deref()
            .is_some_and(|previous| previous != identity)
        {
            return Err(Error::new(
                409,
                "this account is linked to another Battle.net player",
            ));
        }
        if existing.is_none() {
            tx.execute(
                "UPDATE upload_tokens SET revoked_at=?1 WHERE fingerprint=?2",
                params![now(), fingerprint],
            )?;
        }
        tx.execute(
            "UPDATE upload_identities SET battlenet_identity=?1 WHERE fingerprint=?2",
            params![identity, fingerprint],
        )?;
    }
    tx.execute(
        "INSERT INTO upload_tokens (token_hash,fingerprint,created_at) VALUES (?1,?2,?3)",
        params![hash(&token), fingerprint, now()],
    )?;
    tx.commit()?;
    let mut reply = Reply::json(json!({"token":token}));
    reply.headers.push(("cache-control", "no-store".into()));
    Ok(reply)
}

fn upload_scan(input: &Input, db: &mut Connection) -> Result<Reply> {
    let scan = input.upload(goldbook_core::parse_scan_upload)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let inserted = tx.execute("INSERT INTO scans (realm,faction,region,scanned_at,mode,scanner,build,item_count,uploaded_at,fingerprint) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,unixepoch(),?9) ON CONFLICT(fingerprint) DO NOTHING",params![scan.realm,scan.faction,scan.region,scan.scanned_at as i64,scan.mode,scan.scanner,scan.build,scan.rows.len() as i64,scan.fingerprint()])?;
    let id = tx.last_insert_rowid();
    {
        let mut items = tx.prepare("INSERT INTO items (item_key,name,quality) VALUES (?1,?2,?3) ON CONFLICT(item_key) DO UPDATE SET name=excluded.name,quality=excluded.quality WHERE items.name IS NOT excluded.name OR items.quality IS NOT excluded.quality")?;
        for (key, (name, quality)) in &scan.items {
            items.execute(params![key, name, *quality as i64])?;
        }
        if inserted == 1 {
            let mut prices = tx.prepare("INSERT INTO prices (scan_id,item_key,min_buyout,market_value,quantity,num_auctions) VALUES (?1,?2,?3,?4,?5,?6)")?;
            for (key, min, market, quantity, auctions) in &scan.rows {
                prices.execute(params![
                    id,
                    key,
                    *min as i64,
                    *market as i64,
                    *quantity as i64,
                    *auctions as i64
                ])?;
            }
        }
    }
    tx.commit()?;
    Ok(Reply::json(
        json!({"stored":inserted==1,"items":scan.rows.len()}),
    ))
}
fn upload_sellers(input: &Input, db: &mut Connection) -> Result<Reply> {
    let snapshot = input.upload(goldbook_core::parse_seller_snapshot)?;
    let inserted = db.execute(
        "INSERT INTO seller_snapshots (fingerprint,realm,faction,item_key,scanned_at,payload) VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(fingerprint) DO NOTHING",
        params![snapshot.fingerprint(), snapshot.realm, snapshot.faction, snapshot.item_key,
            snapshot.scanned_at as i64, serde_json::to_string(&snapshot).map_err(|e| Error::new(400, e.to_string()))?],
    )?;
    Ok(Reply::json(json!({"stored": inserted == 1})))
}

fn upload_seller_batch(input: &Input, db: &mut Connection) -> Result<Reply> {
    let snapshots = input.upload(|value| {
        let values = value.as_array().ok_or("seller batch must be an array")?;
        if values.is_empty() || values.len() > goldbook_core::MAX_SELLER_BATCH {
            return Err("seller batch must contain 1 to 100 snapshots".into());
        }
        values
            .iter()
            .map(goldbook_core::parse_seller_snapshot)
            .collect::<std::result::Result<Vec<_>, _>>()
    })?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut inserted = 0;
    {
        let mut statement = tx.prepare_cached(
            "INSERT INTO seller_snapshots (fingerprint,realm,faction,item_key,scanned_at,payload) VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(fingerprint) DO NOTHING",
        )?;
        for snapshot in &snapshots {
            inserted += statement.execute(params![
                snapshot.fingerprint(),
                snapshot.realm,
                snapshot.faction,
                snapshot.item_key,
                snapshot.scanned_at as i64,
                serde_json::to_string(snapshot).map_err(|e| Error::new(400, e.to_string()))?
            ])?;
        }
    }
    tx.commit()?;
    Ok(Reply::json(
        json!({"stored": inserted, "received": snapshots.len()}),
    ))
}

fn sellers(input: &Input, db: &Connection) -> Result<Reply> {
    let realm = required(input, "realm")?;
    let faction = required(input, "faction")?;
    let key = required(input, "itemKey")?;
    let selected = input.query.get("snapshot").map(String::as_str);
    let payload: Option<String> = db.query_row(
        "SELECT payload FROM seller_snapshots WHERE realm=?1 AND faction=?2 AND item_key=?3 AND (?4 IS NULL OR fingerprint=?4) ORDER BY scanned_at DESC,rowid DESC LIMIT 1",
        params![realm, faction, key, selected], |row| row.get(0),
    ).optional()?;
    let Some(payload) = payload else {
        return Ok(Reply::json(json!({"snapshot": null})));
    };
    let snapshot: goldbook_core::SellerSnapshot =
        serde_json::from_str(&payload).map_err(|e| Error::new(500, e.to_string()))?;
    let mut response = json!({"snapshot": {"id": snapshot.fingerprint(),
        "scannedAt": snapshot.scanned_at, "itemKey": snapshot.item_key,
        "summary": snapshot.summary(), "orderBook": snapshot.order_book()}});
    if input.query.get("history").is_some_and(|v| v == "1") {
        let mut statement = db.prepare(
            "SELECT fingerprint,scanned_at FROM seller_snapshots WHERE realm=?1 AND faction=?2 AND item_key=?3 ORDER BY scanned_at DESC,rowid DESC",
        )?;
        let history = statement
            .query_map(params![realm, faction, key], |row| {
                Ok(json!({"id": row.get::<_, String>(0)?, "scannedAt": row.get::<_, i64>(1)?}))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        response["history"] = json!(history);
    }
    Ok(Reply::json(response))
}

fn search(input: &Input) -> Result<&str> {
    let search = input.query.get("q").map(String::as_str).unwrap_or("");
    if search.encode_utf16().count() > 100 {
        return Err(Error::new(400, "q must be at most 100 characters"));
    }
    Ok(search)
}
/// The items a price list shows, as `q`, `profession`, `kind` and `quality`
/// select them. MATCHING reads them from ?4, ?6 and ?7.
struct Filter<'a> {
    search: &'a str,
    selected: Option<String>,
    quality: Option<i64>,
}
const MATCHING: &str = "(?4='' OR instr(lower(i.name),lower(?4))>0 OR p.item_key=?4) AND (?6 IS NULL OR CAST(p.item_key AS INTEGER) IN (SELECT value FROM json_each(?6))) AND (?7 IS NULL OR i.quality=?7)";
impl<'a> Filter<'a> {
    fn parse(input: &Input, search: &'a str) -> Result<Self> {
        let profession = input
            .query
            .get("profession")
            .map(String::as_str)
            .unwrap_or("");
        let kind = input.query.get("kind").map(String::as_str).unwrap_or("all");
        let selected =
            goldbook_core::profession_items(profession, kind).map_err(|e| Error::new(400, e))?;
        let quality = match input.query.get("quality").map(String::as_str) {
            None | Some("") => None,
            Some(_) => Some(integer(input, "quality", 0, 7)?),
        };
        Ok(Self {
            search,
            selected: selected.map(|ids| serde_json::to_string(&ids).unwrap()),
            quality,
        })
    }
    fn is_empty(&self) -> bool {
        self.search.is_empty() && self.selected.is_none() && self.quality.is_none()
    }
}
fn prices(input: &Input, db: &Connection) -> Result<Reply> {
    let realm = required(input, "realm")?;
    let faction = required(input, "faction")?;
    // q is checked before sort and order, and the other filters after them.
    let search = search(input)?;
    let (sort, sort_join) = match input
        .query
        .get("sort")
        .map(String::as_str)
        .unwrap_or("name")
    {
        "name" => (
            "COALESCE(i.name,p.item_key) COLLATE NOCASE".to_owned(),
            NAMED,
        ),
        "min" => ("p.min_buyout".to_owned(), ""),
        "market" => (format!("NULLIF({MARKET},0)"), MARKET_JOIN),
        "quantity" => ("p.quantity".to_owned(), ""),
        _ => {
            return Err(Error::new(
                400,
                "sort must be one of name, min, market, quantity",
            ));
        }
    };
    let order = match input
        .query
        .get("order")
        .map(String::as_str)
        .unwrap_or("asc")
    {
        "asc" => "ASC",
        "desc" => "DESC",
        _ => return Err(Error::new(400, "order must be one of asc, desc")),
    };
    let filter = Filter::parse(input, search)?;
    let limit = integer(input, "limit", 50, 200)?;
    let offset = integer(input, "offset", 0, 9007199254740991)?;
    let scan = db::query(
        db,
        &format!("{SCANS} ORDER BY scanned_at DESC,id DESC LIMIT 1"),
        &[&realm, &faction],
    )?
    .into_iter()
    .next()
    .ok_or_else(|| Error::new(404, "no scans for this realm and faction"))?;
    let full = db::query(
        db,
        &format!("{SCANS} AND mode='replicate' ORDER BY scanned_at DESC,id DESC LIMIT 1"),
        &[&realm, &faction],
    )?
    .into_iter()
    .next();
    let id = scan["id"].as_i64().unwrap();
    let borrowed = full
        .as_ref()
        .and_then(|f| f["id"].as_i64())
        .filter(|n| *n != id);
    let order = format!("ORDER BY {sort} {order} NULLS LAST,p.item_key");
    let page = format!("{order} LIMIT ?2 OFFSET ?3");
    let columns = format!(
        "p.item_key AS itemKey,i.name,i.quality,p.min_buyout AS minBuyout,{MARKET} AS marketValue,p.quantity,p.num_auctions AS numAuctions"
    );
    let bindings: [&dyn rusqlite::ToSql; 7] = [
        &id,
        &limit,
        &offset,
        &filter.search,
        &borrowed,
        &filter.selected,
        &filter.quality,
    ];
    if filter.is_empty() {
        let sql = format!(
            "SELECT {columns} FROM (SELECT p.* FROM prices p {sort_join} WHERE p.scan_id=?1 {page}) p {NAMED} {MARKET_JOIN} {order}"
        );
        return Ok(Reply::json(
            json!({"scan":scan,"marketScan":full,"total":scan["itemCount"],"items":db::query(db,&sql,&bindings[..5])?}),
        ));
    }
    let matching = format!("FROM prices p {NAMED} {MARKET_JOIN} WHERE p.scan_id=?1 AND {MATCHING}");
    let mut items = db::query(
        db,
        &format!("SELECT {columns},COUNT(*) OVER() AS total {matching} {page}"),
        &bindings,
    )?;
    let total = if let Some(item) = items.first() {
        item["total"].clone()
    } else if offset > 0 || limit == 0 {
        db::query(
            db,
            &format!("SELECT COUNT(*) AS total {matching}"),
            &bindings,
        )?[0]["total"]
            .clone()
    } else {
        json!(0)
    };
    for item in &mut items {
        item.as_object_mut().unwrap().remove("total");
    }
    Ok(Reply::json(
        json!({"scan":scan,"marketScan":full,"total":total,"items":items}),
    ))
}
/// An item of the newest scan, priced as the addon prices it after merging
/// the server's export.
struct Listing {
    item_key: String,
    name: Option<String>,
    quality: Option<i64>,
    quantity: u64,
    record: PriceRecord,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Advised<T> {
    item_key: String,
    name: Option<String>,
    quality: Option<i64>,
    min_buyout: u64,
    #[serde(flatten)]
    advice: T,
    quantity: u64,
}
impl Listing {
    fn advised<T>(self, advice: T) -> Advised<T> {
        Advised {
            item_key: self.item_key,
            name: self.name,
            quality: self.quality,
            min_buyout: self.record.min,
            advice,
            quantity: self.quantity,
        }
    }
}
/// The realm's newest scan and the items of it that `filter` selects, with
/// the daily lows of the export's window of 61 days.
fn listings(
    db: &Connection,
    realm: &str,
    faction: &str,
    filter: &Filter,
) -> Result<(Value, Vec<Listing>)> {
    let scan = db::query(
        db,
        &format!("{SCANS} ORDER BY scanned_at DESC,id DESC LIMIT 1"),
        &[&realm, &faction],
    )?
    .into_iter()
    .next()
    .ok_or_else(|| Error::new(404, "no scans for this realm and faction"))?;
    let id = scan["id"].as_i64().unwrap();
    let first = (scan["scannedAt"].as_i64().unwrap() / 86400 - 60) * 86400;
    let bindings: [&dyn rusqlite::ToSql; 7] = [
        &id,
        &realm,
        &faction,
        &filter.search,
        &first,
        &filter.selected,
        &filter.quality,
    ];
    let matching = format!("FROM prices p {NAMED} WHERE p.scan_id=?1 AND {MATCHING}");
    let mut days: HashMap<String, Vec<[i64; 4]>> = HashMap::new();
    // The unary plus keeps SQLite from looking each item up in each scan,
    // which for a whole realm is slower than reading the scans whole.
    let mut statement = db.prepare(&format!(
        "SELECT p.item_key,s.scanned_at/86400,p.min_buyout FROM scans s JOIN prices p ON p.scan_id=s.id WHERE s.realm=?2 AND s.faction=?3 AND s.scanned_at>=?5 AND +p.item_key IN (SELECT p.item_key {matching}) ORDER BY s.scanned_at"
    ))?;
    let mut rows = statement.query(&bindings[..])?;
    while let Some(row) = rows.next()? {
        let lows = days.entry(row.get(0)?).or_default();
        add_to_bucket(lows, row.get(1)?, row.get(2)?, 0, 0);
    }
    let mut statement = db.prepare(&format!(
        "SELECT p.item_key,i.name,i.quality,p.quantity,p.min_buyout,p.market_value {matching}"
    ))?;
    let listings = statement
        .query_map(&bindings[..], |row| {
            let item_key: String = row.get(0)?;
            let lows = days.remove(&item_key).unwrap_or_default();
            let lows = &lows[lows.len().saturating_sub(HISTORY_DAYS)..];
            Ok(Listing {
                name: row.get(1)?,
                quality: row.get(2)?,
                quantity: unsigned(row, 3)?,
                record: PriceRecord {
                    min: unsigned(row, 4)?,
                    market: Some(unsigned(row, 5)?).filter(|market| *market > 0),
                    days: lows.iter().map(|day| day[1] as u64).collect(),
                },
                item_key,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok((scan, listings))
}
// Uploads store no negative prices or quantities.
fn unsigned(row: &rusqlite::Row, index: usize) -> rusqlite::Result<u64> {
    row.get::<_, i64>(index).map(|n| n as u64)
}
fn page<T>(items: Vec<T>, limit: i64, offset: i64) -> Vec<T> {
    items
        .into_iter()
        .skip(offset as usize)
        .take(limit as usize)
        .collect()
}
fn deals(input: &Input, db: &Connection) -> Result<Reply> {
    let realm = required(input, "realm")?;
    let faction = required(input, "faction")?;
    let filter = Filter::parse(input, search(input)?)?;
    // The addon's DEFAULT_MIN_PROFIT.
    let min_profit = integer(input, "minProfit", 1000, 9007199254740991)?;
    let limit = integer(input, "limit", 50, 200)?;
    let offset = integer(input, "offset", 0, 9007199254740991)?;
    let (scan, listings) = listings(db, realm, faction, &filter)?;
    let mut deals: Vec<_> = listings
        .into_iter()
        .filter_map(|listing| {
            let stocked = goldbook_core::merchant_sells(&listing.item_key);
            let flip = goldbook_core::flip(&listing.record, stocked)?;
            (flip.profit >= min_profit as u64).then(|| listing.advised(flip))
        })
        .collect();
    deals.sort_by(|a, b| {
        b.advice
            .profit
            .cmp(&a.advice.profit)
            .then_with(|| a.item_key.cmp(&b.item_key))
    });
    Ok(Reply::json(json!({
        "scan": scan,
        "minProfit": min_profit,
        "total": deals.len(),
        "items": page(deals, limit, offset),
    })))
}
fn movers(input: &Input, db: &Connection) -> Result<Reply> {
    let realm = required(input, "realm")?;
    let faction = required(input, "faction")?;
    let filter = Filter::parse(input, search(input)?)?;
    let risers = match input
        .query
        .get("direction")
        .map(String::as_str)
        .unwrap_or("risers")
    {
        "risers" => true,
        "fallers" => false,
        _ => {
            return Err(Error::new(400, "direction must be one of risers, fallers"));
        }
    };
    let limit = integer(input, "limit", 50, 200)?;
    let offset = integer(input, "offset", 0, 9007199254740991)?;
    let (scan, listings) = listings(db, realm, faction, &filter)?;
    let mut movers: Vec<_> = listings
        .into_iter()
        .filter_map(|listing| {
            let mover = goldbook_core::mover(&listing.record)?;
            (risers == (mover.change > 0.0)).then(|| listing.advised(mover))
        })
        .collect();
    movers.sort_by(|a, b| {
        let fall = a.advice.change.total_cmp(&b.advice.change);
        let biggest = if risers { fall.reverse() } else { fall };
        biggest.then_with(|| a.item_key.cmp(&b.item_key))
    });
    Ok(Reply::json(json!({
        "scan": scan,
        "total": movers.len(),
        "items": page(movers, limit, offset),
    })))
}
fn history(input: &Input, db: &Connection) -> Result<Reply> {
    let realm = required(input, "realm")?;
    let faction = required(input, "faction")?;
    let key = required(input, "itemKey")?;
    let mut points = db::query(
        db,
        "SELECT s.scanned_at AS scannedAt,s.mode,p.min_buyout AS minBuyout,p.market_value AS marketValue,p.quantity FROM prices p JOIN scans s ON s.id=p.scan_id WHERE s.realm=?1 AND s.faction=?2 AND p.item_key=?3 ORDER BY s.scanned_at DESC,s.id DESC LIMIT 2000",
        &[&realm, &faction, &key],
    )?;
    points.reverse();
    let mut item = db::query(
        db,
        "SELECT name,quality FROM items WHERE item_key=?1",
        &[&key],
    )?
    .into_iter()
    .next()
    .unwrap_or_else(|| json!({}));
    item["itemKey"] = json!(key);
    item["points"] = json!(points);
    Ok(Reply::json(item))
}
fn trends(input: &Input, db: &Connection) -> Result<Reply> {
    let realm = required(input, "realm")?;
    let faction = required(input, "faction")?;
    let mut keys = Vec::new();
    for key in required(input, "items")?.split(',') {
        if !keys.contains(&key) {
            keys.push(key);
        }
    }
    if keys.len() > 200 {
        return Err(Error::new(400, "items must name at most 200 items"));
    }
    let newest: Option<i64> = db.query_row(
        "SELECT MAX(scanned_at) FROM scans WHERE realm=?1 AND faction=?2",
        [realm, faction],
        |r| r.get(0),
    )?;
    let newest = newest
        .filter(|n| *n != 0)
        .ok_or_else(|| Error::new(404, "no scans for this realm and faction"))?;
    let first = (newest / 86400 - 13) * 86400;
    let encoded = serde_json::to_string(&keys).unwrap();
    let last = first + 14 * 86400;
    let rows = db::query(
        db,
        "SELECT p.item_key AS itemKey,s.scanned_at AS scannedAt,p.min_buyout AS minBuyout FROM scans s CROSS JOIN json_each(?4) k CROSS JOIN prices p WHERE s.realm=?1 AND s.faction=?2 AND s.scanned_at>=?3 AND s.scanned_at<?5 AND p.scan_id=s.id AND p.item_key=k.value",
        &[&realm, &faction, &first, &encoded, &last],
    )?;
    let mut items: BTreeMap<String, Vec<Option<i64>>> = BTreeMap::new();
    for row in rows {
        let lows = items
            .entry(row["itemKey"].as_str().unwrap().into())
            .or_insert(vec![None; 14]);
        let day = ((row["scannedAt"].as_i64().unwrap() - first) / 86400) as usize;
        let price = row["minBuyout"].as_i64().unwrap();
        lows[day] = Some(lows[day].map_or(price, |p| p.min(price)));
    }
    Ok(Reply::json(
        json!({"days":(0..14).map(|i|first+i*86400).collect::<Vec<_>>(),"items":items}),
    ))
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Export<'a> {
    realm: &'a str,
    faction: &'a str,
    scanned_at: i64,
    items: BTreeMap<String, ExportItem>,
}
#[derive(Serialize, Default)]
struct ExportItem {
    name: Option<String>,
    quality: Option<i64>,
    price: [i64; 6],
    hours: Vec<[i64; 4]>,
    days: Vec<[i64; 4]>,
}
fn export(input: &Input, db: &Connection) -> Result<Reply> {
    let realm = required(input, "realm")?;
    let faction = required(input, "faction")?;
    let newest: Option<i64> = db.query_row(
        "SELECT MAX(scanned_at) FROM scans WHERE realm=?1 AND faction=?2",
        [realm, faction],
        |r| r.get(0),
    )?;
    let newest = newest.ok_or_else(|| Error::new(404, "no scans for this realm and faction"))?;
    let first_day = newest / 86400 - 60;
    let first_hour = newest / 3600 - 167;
    let mut items: BTreeMap<String, ExportItem> = BTreeMap::new();
    let mut statement = db.prepare(
        "SELECT p.item_key,s.scanned_at,p.min_buyout,p.quantity,p.num_auctions,p.market_value FROM scans s JOIN prices p ON p.scan_id=s.id WHERE s.realm=?1 AND s.faction=?2 AND s.scanned_at>=?3 ORDER BY s.scanned_at,s.id",
    )?;
    let mut rows = statement.query(params![realm, faction, first_day * 86400])?;
    while let Some(row) = rows.next()? {
        let item = items.entry(row.get(0)?).or_default();
        let (at, min, qty, n, mv): (i64, i64, i64, i64, i64) = (
            row.get(1)?,
            row.get(2)?,
            row.get(3)?,
            row.get(4)?,
            row.get(5)?,
        );
        let (price_mv, price_mv_at) = if mv > 0 {
            (mv, at)
        } else {
            (item.price[4], item.price[5])
        };
        item.price = [min, qty, n, at, price_mv, price_mv_at];
        if at / 3600 >= first_hour {
            add_to_bucket(&mut item.hours, at / 3600, min, qty, mv);
        }
        add_to_bucket(&mut item.days, at / 86400, min, qty, mv);
    }
    let keys = serde_json::to_string(&items.keys().collect::<Vec<_>>()).unwrap();
    let mut names = db.prepare(
        "SELECT i.item_key,i.name,i.quality FROM json_each(?1) k JOIN items i ON i.item_key=k.value",
    )?;
    let mut rows = names.query([keys])?;
    while let Some(row) = rows.next()? {
        if let Some(item) = items.get_mut(&row.get::<_, String>(0)?) {
            item.name = Some(row.get(1)?);
            item.quality = Some(row.get(2)?);
        }
    }
    let mut reply = Reply::json(Export {
        realm,
        faction,
        scanned_at: newest,
        items,
    });
    reply.headers.push(("vary", "accept-encoding".into()));
    if accepts_gzip(header(&input.headers, "accept-encoding")) {
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        encoder
            .write_all(&reply.body)
            .map_err(anyhow::Error::from)?;
        reply.body = encoder.finish().map_err(anyhow::Error::from)?;
        reply.headers.push(("content-encoding", "gzip".into()));
    }
    Ok(reply)
}
// Only an explicit gzip counts, so "gzip;q=0" refuses it.
fn accepts_gzip(accept: &str) -> bool {
    accept.split(',').any(|coding| {
        let mut parts = coding.split(';');
        parts
            .next()
            .is_some_and(|name| name.trim().eq_ignore_ascii_case("gzip"))
            && !parts.any(|parameter| {
                parameter
                    .trim()
                    .strip_prefix("q=")
                    .and_then(|q| q.trim().parse::<f64>().ok())
                    == Some(0.0)
            })
    })
}
// Rows arrive oldest first, so a row belongs to the last bucket or starts a new one.
fn add_to_bucket(buckets: &mut Vec<[i64; 4]>, period: i64, min: i64, qty: i64, mv: i64) {
    match buckets.last_mut() {
        Some(last) if last[0] == period => {
            if min < last[1] {
                (last[1], last[2]) = (min, qty);
            }
            if mv > 0 {
                last[3] = mv;
            }
        }
        _ => buckets.push([period, min, qty, mv]),
    }
}
fn upload_account(input: &Input, db: &mut Connection) -> Result<Reply> {
    let account = input.upload(goldbook_core::parse_account_upload)?;
    let mut characters = BTreeMap::new();
    for c in &account.characters {
        characters.insert((&c.name, &c.realm), c);
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let stored: Option<String> = tx
        .query_row(
            "SELECT key_hash FROM accounts WHERE id=?1",
            [&account.id],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(stored) = stored {
        if stored != account.key_hash && Some(&stored) != account.previous_key_hash.as_ref() {
            return Err(Error::new(409, "this ID belongs to another key"));
        }
        if stored != account.key_hash {
            tx.execute("DELETE FROM sessions WHERE account_id=?1", [&account.id])?;
            // A new key also shuts out the other players who uploaded the ID.
            tx.execute(
                "DELETE FROM account_identities WHERE account_id=?1",
                [&account.id],
            )?;
        }
    }
    tx.execute("INSERT INTO accounts (id,key_hash,updated_at) VALUES (?1,?2,?3) ON CONFLICT(id) DO UPDATE SET key_hash=excluded.key_hash,updated_at=excluded.updated_at",params![account.id,account.key_hash,now()])?;
    tx.execute("DELETE FROM characters WHERE account_id=?1", [&account.id])?;
    {
        let mut insert = tx.prepare("INSERT INTO characters (account_id,name,realm,faction,class,level,updated_at,gold,bags,bank) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)")?;
        for c in characters.values() {
            insert.execute(params![
                account.id,
                c.name,
                c.realm,
                c.faction,
                c.class,
                c.level.map(|v| v as i64),
                c.updated_at.map(|v| v as i64),
                serde_json::to_string(&c.gold).unwrap(),
                c.bags.as_ref().map(|v| serde_json::to_string(v).unwrap()),
                c.bank.as_ref().map(|v| serde_json::to_string(v).unwrap())
            ])?;
        }
    }
    {
        let mut insert = tx.prepare("INSERT INTO trades (account_id,name,realm,at,side,item,count,price,fee,copy,item_key,party) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12) ON CONFLICT (account_id,name,realm,at,side,item,count,price,fee,copy) DO UPDATE SET item_key=COALESCE(item_key,excluded.item_key),party=COALESCE(party,excluded.party)")?;
        let mut copies: BTreeMap<_, i64> = BTreeMap::new();
        for t in &account.trades {
            let copy = copies
                .entry((
                    &t.name, &t.realm, t.at, &t.side, &t.item, t.count, t.price, t.fee,
                ))
                .or_insert(0);
            insert.execute(params![
                account.id,
                t.name,
                t.realm,
                t.at as i64,
                t.side,
                t.item,
                t.count as i64,
                t.price as i64,
                t.fee as i64,
                *copy,
                t.item_key,
                t.party
            ])?;
            *copy += 1;
        }
    }
    if let Some(fingerprint) = &input.uploader {
        tx.execute(
            "INSERT INTO account_identities (account_id,identity_hash,first_seen) SELECT ?1,battlenet_identity,?3 FROM upload_identities WHERE fingerprint=?2 AND battlenet_identity IS NOT NULL ON CONFLICT DO NOTHING",
            params![account.id, fingerprint, now()],
        )?;
    }
    tx.commit()?;
    Ok(Reply::json(
        json!({"stored":true,"characters":characters.len()}),
    ))
}
fn cookie(input: &Input, token: &str, age: i64) -> (&'static str, String) {
    (
        "set-cookie",
        format!(
            "goldbook_session={token}; HttpOnly; SameSite=Strict; Path=/; Max-Age={age}{}",
            if input.secure { "; Secure" } else { "" }
        ),
    )
}
// The ID in `body` and its key hash, if the key is right, else `refused`.
// Wrong keys count against the login limits, whether logging in or linking.
fn verify(
    input: &Input,
    app: &App,
    db: &Connection,
    body: &Value,
    refused: u16,
) -> Result<(String, String)> {
    let id = goldbook_core::normalize_code(body["id"].as_str().unwrap_or(""));
    let key = goldbook_core::normalize_code(body["key"].as_str().unwrap_or(""));
    let well_formed = id.len() == 8 && key.len() == 20;
    let now = now();
    let wait = app.logins.lock().unwrap().begin(
        well_formed.then_some(id.as_str()),
        input.client.as_deref(),
        now,
    );
    if wait > 0 {
        let minutes = (wait + 59) / 60;
        return Err(Error::new(
            429,
            format!(
                "too many attempts, try again in {minutes} minute{}",
                if minutes == 1 { "" } else { "s" }
            ),
        ));
    }
    let stored: Option<String> = if well_formed {
        db.query_row("SELECT key_hash FROM accounts WHERE id=?1", [&id], |r| {
            r.get(0)
        })
        .optional()?
    } else {
        None
    };
    let calculated = goldbook_core::key_hash(&key);
    let matches = calculated.as_bytes().ct_eq(
        stored
            .as_deref()
            .unwrap_or("0000000000000000000000000000000000000000000000000000000000000000")
            .as_bytes(),
    );
    let Some(stored) = stored.filter(|_| bool::from(matches)) else {
        return Err(Error::new(refused, "wrong ID or key"));
    };
    app.logins
        .lock()
        .unwrap()
        .succeed(&id, input.client.as_deref(), now);
    Ok((id, stored))
}
fn authenticate(
    input: &Input,
    app: &App,
    db: &mut Connection,
    body: Value,
    // From the desktop app: the website's view to send the browser on to.
    desktop: Option<&str>,
) -> Result<Reply> {
    let (id, stored) = verify(input, app, db, &body, 401)?;
    let now = now();
    let token = URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>());
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute("DELETE FROM sessions WHERE expires_at<=?1", [now])?;
    let inserted = tx.execute("INSERT INTO sessions (token_hash,account_id,expires_at) SELECT ?1,id,?3 FROM accounts WHERE id=?2 AND key_hash=?4",params![hash(&token),id,now+SESSION_SECONDS,stored])?;
    tx.commit()?;
    if inserted == 0 {
        return Err(Error::new(401, "wrong ID or key"));
    }
    let mut r = Reply::json(json!({"id":id}));
    r.headers.push(cookie(input, &token, SESSION_SECONDS));
    if let Some(view) = desktop {
        r.status = 303;
        r.headers.push(("location", format!("../#{view}")));
        r.headers.push(("cache-control", "no-store".into()));
    }
    Ok(r)
}
// The ID the session logged in with, and the ID its group is kept under.
fn account_of(input: &Input, db: &Connection) -> Result<(String, String)> {
    db.query_row(
        "SELECT a.id,COALESCE(a.owner_id,a.id) FROM sessions s JOIN accounts a ON a.id=s.account_id WHERE s.token_hash=?1 AND s.expires_at>?2",
        params![hash(input.cookie()), now()],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()?
    .ok_or_else(|| Error::new(401, "not logged in"))
}
// The other IDs of the group kept under `owner`.
fn linked(db: &Connection, id: &str, owner: &str) -> Result<Vec<String>> {
    let mut stmt = db.prepare(&format!("{GROUP} AND id<>?2 ORDER BY id"))?;
    let ids = stmt
        .query_map([owner, id], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(ids)
}
// Links the ID in the body with the session's, and with that every ID either
// was linked with.
fn link(input: &Input, app: &App, db: &mut Connection) -> Result<Reply> {
    let (id, _) = account_of(input, db)?;
    let (other, _) = verify(input, app, db, &input.json()?, 403)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let owner_of = |id: &str| -> rusqlite::Result<String> {
        tx.query_row(
            "SELECT COALESCE(owner_id,id) FROM accounts WHERE id=?1",
            [id],
            |r| r.get(0),
        )
    };
    let (owner, joining) = (owner_of(&id)?, owner_of(&other)?);
    if joining != owner {
        tx.execute(
            "UPDATE accounts SET owner_id=?1 WHERE COALESCE(owner_id,id)=?2",
            [&owner, &joining],
        )?;
    }
    let linked = linked(&tx, &id, &owner)?;
    tx.commit()?;
    Ok(Reply::json(json!({ "linked": linked })))
}
// The group's characters, each one as merged from every ID that uploaded it:
// the details of its newest upload, the gold of all of them with the newer
// upload winning an hour both have, and the newest bags and bank. Gold is
// [[time, copper]] by time, bags and bank as uploaded or null.
fn group_characters(
    db: &Connection,
    owner: &str,
    filter: &str,
    params: &[&dyn rusqlite::ToSql],
) -> Result<Vec<Value>> {
    let rows = db::query(
        db,
        &format!(
            "SELECT {CHARACTER_COLUMNS},gold,bags,bank FROM characters WHERE account_id IN ({GROUP}){filter} ORDER BY updated_at NULLS FIRST"
        ),
        &[&[&owner as &dyn rusqlite::ToSql], params].concat(),
    )?;
    let decode = |text: &Value| -> Result<Value> {
        text.as_str().map_or(Ok(Value::Null), |text| {
            serde_json::from_str(text).map_err(|e| Error::from(anyhow::Error::from(e)))
        })
    };
    let mut merged: BTreeMap<(String, String), (Value, BTreeMap<u64, u64>)> = BTreeMap::new();
    for mut row in rows {
        let key = (
            row["name"].as_str().unwrap().to_owned(),
            row["realm"].as_str().unwrap().to_owned(),
        );
        let gold: Vec<(u64, u64)> = serde_json::from_value(decode(&row["gold"])?)
            .map_err(|e| Error::from(anyhow::Error::from(e)))?;
        let (bags, bank) = (decode(&row["bags"])?, decode(&row["bank"])?);
        let (character, hours) = merged
            .entry(key)
            .or_insert_with(|| (Value::Null, BTreeMap::new()));
        hours.extend(gold);
        for (name, container) in [("bags", bags), ("bank", bank)] {
            let held = &character[name];
            row[name] = if container.is_null() || held["at"].as_u64() > container["at"].as_u64() {
                held.clone()
            } else {
                container
            };
        }
        *character = row;
    }
    Ok(merged
        .into_values()
        .map(|(mut character, hours)| {
            character["gold"] = json!(hours.into_iter().collect::<Vec<_>>());
            character
        })
        .collect())
}
fn characters(input: &Input, db: &Connection) -> Result<Reply> {
    let (id, owner) = account_of(input, db)?;
    let mut characters = group_characters(db, &owner, "", &[])?;
    for c in &mut characters {
        let object = c.as_object_mut().unwrap();
        object.remove("bags");
        object.remove("bank");
        let gold = object["gold"]
            .as_array()
            .unwrap()
            .last()
            .map_or(Value::Null, |point| point[1].clone());
        object.insert("gold".into(), gold);
    }
    characters.sort_by(|a, b| {
        b["gold"]
            .as_u64()
            .cmp(&a["gold"].as_u64())
            .then_with(|| a["name"].as_str().cmp(&b["name"].as_str()))
            .then_with(|| a["realm"].as_str().cmp(&b["realm"].as_str()))
    });
    Ok(Reply::json(
        json!({"id":id,"linked":linked(db,&id,&owner)?,"characters":characters}),
    ))
}
fn container(mut found: Value) -> Result<Value> {
    if found.is_null() {
        return Ok(found);
    }
    let rows = found["rows"]
        .as_array_mut()
        .ok_or_else(|| Error::new(500, "internal error"))?;
    rows.sort_by(|a, b| b["value"].as_u64().cmp(&a["value"].as_u64()));
    // 1,000 maximum-safe integers fit in u64, but exceed exact JSON doubles.
    let total: u64 = rows.iter().map(|r| r["value"].as_u64().unwrap_or(0)).sum();
    found["total"] = json!(total);
    Ok(found)
}
fn character(input: &Input, db: &Connection) -> Result<Reply> {
    let (_, owner) = account_of(input, db)?;
    let name = required(input, "name")?;
    let realm = required(input, "realm")?;
    let mut c = group_characters(db, &owner, " AND name=?2 AND realm=?3", &[&name, &realm])?
        .pop()
        .ok_or_else(|| Error::new(404, "no such character"))?;
    c["bags"] = container(c["bags"].take())?;
    c["bank"] = container(c["bank"].take())?;
    Ok(Reply::json(c))
}
// The group's trades, newest first, or one character's with name and realm. A
// trade that more than one ID uploaded counts once.
fn trades(input: &Input, db: &Connection) -> Result<Reply> {
    let (_, owner) = account_of(input, db)?;
    let name = input.query.get("name").map(String::as_str).unwrap_or("");
    let realm = if name.is_empty() {
        ""
    } else {
        required(input, "realm")?
    };
    let rows = db::query(
        db,
        &format!(
            "SELECT t.name,t.realm,t.at,t.side,t.item,t.itemKey,i.quality,t.count,t.price,t.fee,t.party FROM (SELECT name,realm,at,side,item,MAX(item_key) AS itemKey,count,price,fee,copy,MAX(party) AS party FROM trades WHERE account_id IN ({GROUP}) AND (?2='' OR (name=?2 AND realm=?3)) GROUP BY name,realm,at,side,item,count,price,fee,copy) t LEFT JOIN items i ON i.item_key=t.itemKey ORDER BY t.at DESC,t.name,t.realm,t.item,t.copy"
        ),
        &[&owner, &name, &realm],
    )?;
    Ok(Reply::json(json!({"trades": rows})))
}
const ASSETS: [(&str, &[u8], &str); 7] = [
    ("app.js", include_bytes!("../../../web/app.js"), "js"),
    ("theme.js", include_bytes!("../../../web/theme.js"), "js"),
    ("style.css", include_bytes!("../../../web/style.css"), "css"),
    (
        "fonts/marcellus-latin-400-normal.woff2",
        include_bytes!("../../../web/fonts/marcellus-latin-400-normal.woff2"),
        "woff2",
    ),
    (
        "fonts/roboto-condensed-latin-400-normal.woff2",
        include_bytes!("../../../web/fonts/roboto-condensed-latin-400-normal.woff2"),
        "woff2",
    ),
    (
        "fonts/roboto-condensed-latin-500-normal.woff2",
        include_bytes!("../../../web/fonts/roboto-condensed-latin-500-normal.woff2"),
        "woff2",
    ),
    (
        "fonts/roboto-condensed-latin-700-normal.woff2",
        include_bytes!("../../../web/fonts/roboto-condensed-latin-700-normal.woff2"),
        "woff2",
    ),
];
// Cloudflare overrides the origin's cache headers for js and css, so a changed asset needs a new URL.
static INDEX: LazyLock<Vec<u8>> = LazyLock::new(|| {
    let mut index = include_str!("../../../web/index.html").to_owned();
    for (name, bytes, _) in ASSETS {
        let version = &hex::encode(Sha256::digest(bytes))[..12];
        index = index.replace(&format!("\"{name}\""), &format!("\"{name}?v={version}\""));
    }
    index.into_bytes()
});
fn static_file(web: Option<&Path>, path: &str) -> Option<Reply> {
    let (body, extension) = if let Some(web) = web {
        let web = web.canonicalize().ok()?;
        let path = web.join(if path == "/" {
            "index.html"
        } else {
            path.trim_start_matches('/')
        });
        let file = path.canonicalize().ok()?;
        if !file.starts_with(&web) || !file.is_file() {
            return None;
        }
        (
            std::fs::read(&file).ok()?,
            file.extension()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_owned(),
        )
    } else {
        match path {
            "/" | "/index.html" => (INDEX.clone(), "html".into()),
            _ => {
                let (_, body, extension) = ASSETS
                    .iter()
                    .find(|(name, ..)| path.strip_prefix('/') == Some(*name))?;
                (body.to_vec(), (*extension).into())
            }
        }
    };
    let content_type = match extension.as_str() {
        "html" => "text/html; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "ico" => "image/x-icon",
        "woff2" => "font/woff2",
        "json" => "application/json",
        _ => "application/octet-stream",
    };
    Some(Reply {
        status: 200,
        body,
        content_type,
        headers: vec![("cache-control", "no-cache".into())],
    })
}
