use super::required;
use crate::{Error, Input, Reply, Result, db, header, house::House};
use flate2::{Compression, write::GzEncoder};
use goldbook_core::{HISTORY_DAYS, PriceRecord};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    io::Write,
};

const SCANS: &str = "SELECT id, scanned_at AS scannedAt, mode, item_count AS itemCount, scanner FROM scans WHERE house=?1 AND faction=?2";
const NAMED: &str = "LEFT JOIN items i ON i.item_key=p.item_key";
// An item's market value is its newest price's own, else the one in the newest
// full scan, else the one in the newest full scan a player uploaded: Battle.net
// snapshots leave out variants, which keep the market value players measured.
const MARKET_JOIN: &str = "LEFT JOIN prices m ON m.scan_id=?5 AND m.item_key=p.item_key LEFT JOIN prices mp ON mp.scan_id=?10 AND mp.item_key=p.item_key";
const MARKET: &str =
    "COALESCE(NULLIF(p.market_value,0),NULLIF(m.market_value,0),mp.market_value,0)";
const MARKET_AT: &str = "CASE WHEN p.market_value>0 THEN p.scanned_at WHEN m.market_value>0 THEN (SELECT scanned_at FROM scans WHERE id=m.scan_id) WHEN mp.market_value>0 THEN (SELECT scanned_at FROM scans WHERE id=mp.scan_id) END";
/// The house and faction a read answers for, from the `realm` and `faction`
/// the client asked for. The only place a realm becomes a house.
fn market(input: &Input) -> Result<(House, &str)> {
    let realm = required(input, "realm")?;
    let faction = required(input, "faction")?;
    Ok((House::of(realm), faction))
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

pub(super) fn sellers(input: &Input, db: &Connection) -> Result<Reply> {
    let (house, faction) = market(input)?;
    let key = required(input, "itemKey")?;
    let selected = input.query.get("snapshot").map(String::as_str);
    let payload: Option<String> = db.query_row(
        "SELECT payload FROM seller_snapshots WHERE house=?1 AND faction=?2 AND item_key=?3 AND (?4 IS NULL OR fingerprint=?4) ORDER BY scanned_at DESC,rowid DESC LIMIT 1",
        params![house, faction, key, selected], |row| row.get(0),
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
            "SELECT fingerprint,scanned_at FROM seller_snapshots WHERE house=?1 AND faction=?2 AND item_key=?3 ORDER BY scanned_at DESC,rowid DESC",
        )?;
        let history = statement
            .query_map(params![house, faction, key], |row| {
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
pub(super) fn prices(input: &Input, db: &Connection) -> Result<Reply> {
    let (house, faction) = market(input)?;
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
        &[&house, &faction],
    )?
    .into_iter()
    .next()
    .ok_or_else(|| Error::new(404, "no scans for this realm and faction"))?;
    let full = db::query(
        db,
        &format!("{SCANS} AND mode='replicate' ORDER BY scanned_at DESC,id DESC LIMIT 1"),
        &[&house, &faction],
    )?
    .into_iter()
    .next();
    let measured: Option<i64> = db.query_row(
        "SELECT id FROM scans WHERE house=?1 AND faction=?2 AND mode='replicate' AND scanner<>?3 ORDER BY scanned_at DESC,id DESC LIMIT 1",
        params![house, faction, crate::auctions::SCANNER],
        |row| row.get(0),
    ).optional()?;
    let id = scan["id"].as_i64().unwrap();
    let borrowed = full
        .as_ref()
        .and_then(|f| f["id"].as_i64())
        .filter(|n| *n != id);
    let order = format!("ORDER BY {sort} {order} NULLS LAST,p.item_key");
    let page = format!("{order} LIMIT ?2 OFFSET ?3");
    let columns = format!(
        "p.item_key AS itemKey,i.name,i.quality,p.min_buyout AS minBuyout,{MARKET} AS marketValue,{MARKET_AT} AS marketScannedAt,p.quantity,p.num_auctions AS numAuctions,p.scanned_at AS scannedAt"
    );
    // Every item scanned in the house and faction, at its newest price.
    let latest = "SELECT p.*,ps.scanned_at FROM latest_prices l JOIN prices p ON p.scan_id=l.scan_id AND p.item_key=l.item_key JOIN scans ps ON ps.id=l.scan_id";
    let bindings: [&dyn rusqlite::ToSql; 10] = [
        &id,
        &limit,
        &offset,
        &filter.search,
        &borrowed,
        &filter.selected,
        &filter.quality,
        &house,
        &faction,
        &measured,
    ];
    if filter.is_empty() {
        let sql = format!(
            "SELECT {columns} FROM ({latest} {sort_join} WHERE l.house=?8 AND l.faction=?9 {page}) p {NAMED} {MARKET_JOIN} {order}"
        );
        let total: i64 = db.query_row(
            "SELECT COUNT(*) FROM latest_prices WHERE house=?1 AND faction=?2",
            params![house, faction],
            |row| row.get(0),
        )?;
        return Ok(Reply::json(
            json!({"scan":scan,"marketScan":full,"total":total,"items":db::query(db,&sql,&bindings)?}),
        ));
    }
    let matching = format!(
        "FROM ({latest} WHERE l.house=?8 AND l.faction=?9) p {NAMED} {MARKET_JOIN} WHERE {MATCHING}"
    );
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
/// The house's newest scan and the items of it that `filter` selects, with
/// the daily lows of the export's window of 61 days.
fn listings(
    db: &Connection,
    house: &House,
    faction: &str,
    filter: &Filter,
) -> Result<(Value, Vec<Listing>)> {
    let scan = db::query(
        db,
        &format!("{SCANS} ORDER BY scanned_at DESC,id DESC LIMIT 1"),
        &[house, &faction],
    )?
    .into_iter()
    .next()
    .ok_or_else(|| Error::new(404, "no scans for this realm and faction"))?;
    let id = scan["id"].as_i64().unwrap();
    let first = (scan["scannedAt"].as_i64().unwrap() / 86400 - 60) * 86400;
    let bindings: [&dyn rusqlite::ToSql; 7] = [
        &id,
        house,
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
        "SELECT p.item_key,s.scanned_at/86400,p.min_buyout FROM scans s JOIN prices p ON p.scan_id=s.id WHERE s.house=?2 AND s.faction=?3 AND s.scanned_at>=?5 AND +p.item_key IN (SELECT p.item_key {matching}) ORDER BY s.scanned_at"
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
pub(super) fn deals(input: &Input, db: &Connection) -> Result<Reply> {
    let (house, faction) = market(input)?;
    let filter = Filter::parse(input, search(input)?)?;
    // The addon's DEFAULT_MIN_PROFIT.
    let min_profit = integer(input, "minProfit", 1000, 9007199254740991)?;
    let limit = integer(input, "limit", 50, 200)?;
    let offset = integer(input, "offset", 0, 9007199254740991)?;
    let (scan, listings) = listings(db, &house, faction, &filter)?;
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
pub(super) fn movers(input: &Input, db: &Connection) -> Result<Reply> {
    let (house, faction) = market(input)?;
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
    let (scan, listings) = listings(db, &house, faction, &filter)?;
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
pub(super) fn history(input: &Input, db: &Connection) -> Result<Reply> {
    let (house, faction) = market(input)?;
    let key = required(input, "itemKey")?;
    let mut points = db::query(
        db,
        "SELECT s.scanned_at AS scannedAt,s.mode,p.min_buyout AS minBuyout,p.market_value AS marketValue,p.quantity FROM prices p JOIN scans s ON s.id=p.scan_id WHERE s.house=?1 AND s.faction=?2 AND p.item_key=?3 ORDER BY s.scanned_at DESC,s.id DESC LIMIT 2000",
        &[&house, &faction, &key],
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
pub(super) fn trends(input: &Input, db: &Connection) -> Result<Reply> {
    let (house, faction) = market(input)?;
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
        "SELECT MAX(scanned_at) FROM scans WHERE house=?1 AND faction=?2",
        params![house, faction],
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
        "SELECT p.item_key AS itemKey,s.scanned_at AS scannedAt,p.min_buyout AS minBuyout FROM scans s CROSS JOIN json_each(?4) k CROSS JOIN prices p WHERE s.house=?1 AND s.faction=?2 AND s.scanned_at>=?3 AND s.scanned_at<?5 AND p.scan_id=s.id AND p.item_key=k.value",
        &[&house, &faction, &first, &encoded, &last],
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
pub(super) fn export(input: &Input, db: &Connection) -> Result<Reply> {
    let realm = required(input, "realm")?;
    let (house, faction) = market(input)?;
    let newest: Option<i64> = db.query_row(
        "SELECT MAX(scanned_at) FROM scans WHERE house=?1 AND faction=?2",
        params![house, faction],
        |r| r.get(0),
    )?;
    let newest = newest.ok_or_else(|| Error::new(404, "no scans for this realm and faction"))?;
    let first_day = newest / 86400 - 60;
    let first_hour = newest / 3600 - 167;
    let mut items: BTreeMap<String, ExportItem> = BTreeMap::new();
    let mut statement = db.prepare(
        "SELECT p.item_key,s.scanned_at,p.min_buyout,p.quantity,p.num_auctions,p.market_value FROM scans s JOIN prices p ON p.scan_id=s.id WHERE s.house=?1 AND s.faction=?2 AND s.scanned_at>=?3 ORDER BY s.scanned_at,s.id",
    )?;
    let mut rows = statement.query(params![house, faction, first_day * 86400])?;
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
