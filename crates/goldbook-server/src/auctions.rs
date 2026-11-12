//! Auction snapshots of WoW Forever houses from the Battle.net Game Data API,
//! stored as full scans and order books so that they reach clients like a
//! player's upload, and names from its item API for the items they price that
//! no player has named.
//!
//! `GOLDBOOK_BATTLENET_AUCTIONS=1` switches polling on; unset, nothing here
//! runs. docs/ah-api/README.md records what the API returns.

use crate::{db, house::House};
use anyhow::{Context, Result, anyhow, bail, ensure};
use goldbook_core::{
    AUCTION_POLL_MINUTE, Listing, PriceRow, ScanUpload, SellerOffer, SellerSnapshot,
    next_minute_past_hour, summarize,
};
use reqwest::{
    StatusCode,
    blocking::{Client, Response},
    header::{IF_MODIFIED_SINCE, LAST_MODIFIED},
};
use rusqlite::{Connection, TransactionBehavior, params};
use serde::Deserialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    io::Read,
    path::PathBuf,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub(crate) const SCANNER: &str = "Battle.net";
// The ruleset in the URL does not select the market, but each URL serves its
// own cached copy, so every snapshot of a house comes through the same one.
const RULESET: u32 = 1;
const NAMESPACE: &str = "dynamic-forever-eu";
const REGION: &str = "EU";
const MAX_BODY: u64 = 128 * 1024 * 1024;
const TOKEN_MARGIN: u64 = 300;

/// One server house and faction, and the API house that lists its auctions.
struct Source {
    house: &'static str,
    faction: &'static str,
    id: u32,
}
impl std::fmt::Display for Source {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}/{} (house {})", self.house, self.faction, self.id)
    }
}

/// The houses polled for now. docs/ah-api/README.md confirms 113, 114 and 116
/// against player scans; 110, 111 and 117 follow from the ID sets. A neutral
/// (Blackwater) house is stored under the faction `Neutral`, as the addon
/// files a scan taken at a neutral auctioneer.
const SOURCES: [Source; 6] = [
    Source {
        house: "EU PvP",
        faction: "Horde",
        id: 113,
    },
    Source {
        house: "EU PvP",
        faction: "Alliance",
        id: 110,
    },
    Source {
        house: "EU PvE",
        faction: "Horde",
        id: 114,
    },
    Source {
        house: "EU PvE",
        faction: "Alliance",
        id: 111,
    },
    Source {
        house: "EU PvP",
        faction: "Neutral",
        id: 116,
    },
    Source {
        house: "EU PvE",
        faction: "Neutral",
        id: 117,
    },
];

/// The item API's namespaces that name an item, in the order they are asked,
/// and the source each name records. Classic Era rates some items a quality
/// lower than Forever and the players' clients do, so it only names the items
/// that Forever does not know. A player's scan corrects a name or quality
/// that differs.
const NAME_SOURCES: [(&str, &str); 2] = [
    ("static-forever-eu", "battlenet-forever"),
    ("static-classic1x-eu", "battlenet-classic-era"),
];
/// The item API's quality types in the order of the addon's
/// `Enum.ItemQuality`, the numbers `items.quality` stores.
const QUALITIES: [&str; 8] = [
    "POOR",
    "COMMON",
    "UNCOMMON",
    "RARE",
    "EPIC",
    "LEGENDARY",
    "ARTIFACT",
    "HEIRLOOM",
];

#[derive(Clone, Debug)]
pub struct AuctionConfig {
    client_id: String,
    client_secret: String,
    // Tests point these at a loopback server, and do not pause.
    pub token_endpoint: String,
    pub api: String,
    pub retry_pause: Duration,
    /// How long one pass may spend naming items, so that the next hour's poll
    /// starts on time. The next pass names the rest.
    pub naming_budget: Duration,
}
impl AuctionConfig {
    pub(crate) fn from_env() -> Result<Option<Self>> {
        let [switch, id, secret] = [
            "GOLDBOOK_BATTLENET_AUCTIONS",
            "BNET_CLIENT_ID",
            "BNET_CLIENT_SECRET",
        ]
        .map(|name| std::env::var(name).unwrap_or_default());
        Self::parse(&switch, &id, &secret)
    }
    /// The poller's settings when `switch` is `1`; None when it is `0` or blank.
    pub fn parse(switch: &str, client_id: &str, client_secret: &str) -> Result<Option<Self>> {
        match switch.trim() {
            "" | "0" => return Ok(None),
            "1" => {}
            other => {
                bail!("GOLDBOOK_BATTLENET_AUCTIONS is {other:?}; set it to 1 for on, or 0 for off")
            }
        }
        ensure!(
            !client_id.trim().is_empty() && !client_secret.trim().is_empty(),
            "GOLDBOOK_BATTLENET_AUCTIONS needs BNET_CLIENT_ID and BNET_CLIENT_SECRET"
        );
        Ok(Some(Self {
            client_id: client_id.into(),
            client_secret: client_secret.into(),
            token_endpoint: "https://oauth.battle.net/token".into(),
            api: "https://eu.api.blizzard.com".into(),
            retry_pause: Duration::from_secs(30),
            naming_budget: Duration::from_secs(20 * 60),
        }))
    }
    fn auctions_url(&self, source: &Source, list: &str) -> String {
        format!(
            "{}/data/wow/ruleset/{RULESET}/auctions/{}{list}?namespace={NAMESPACE}",
            self.api.trim_end_matches('/'),
            source.id
        )
    }
    fn item_url(&self, namespace: &str, item: &str) -> String {
        format!(
            "{}/data/wow/item/{item}?namespace={namespace}&locale=en_US",
            self.api.trim_end_matches('/')
        )
    }
}

#[derive(Deserialize)]
struct Auctions<T> {
    // An empty house has no `auctions` key.
    #[serde(default = "Vec::new")]
    auctions: Vec<T>,
}
#[derive(Deserialize)]
struct Item {
    id: u64,
    #[serde(default)]
    bonus_lists: Vec<u64>,
}
#[derive(Deserialize)]
struct RegularListing {
    item: Item,
    quantity: u64,
    buyout: Option<u64>,
}
#[derive(Deserialize)]
struct CommodityListing {
    item: Item,
    quantity: u64,
    unit_price: u64,
}
#[derive(Deserialize)]
struct NamedItem {
    name: String,
    quality: Quality,
}
#[derive(Deserialize)]
struct Quality {
    r#type: String,
}

/// A house's two lists as buyout listings by plain item ID. The API's bonus
/// IDs are not the addon's suffixes, so a variant with `bonus_lists` would mix
/// its price into the base item's; it is left out, as is a listing without a
/// buyout.
fn listings(
    regular: Auctions<RegularListing>,
    commodities: Auctions<CommodityListing>,
) -> BTreeMap<u64, Vec<Listing>> {
    let regular = regular.auctions.into_iter().map(|listing| {
        let price = listing
            .buyout
            .unwrap_or(0)
            .div_ceil(listing.quantity.max(1));
        (listing.item, price, listing.quantity)
    });
    let commodities = commodities
        .auctions
        .into_iter()
        .map(|listing| (listing.item, listing.unit_price, listing.quantity));
    let mut items: BTreeMap<u64, Vec<Listing>> = BTreeMap::new();
    for (item, price, count) in regular.chain(commodities) {
        if item.id > 0 && item.bonus_lists.is_empty() && price > 0 && count > 0 {
            items
                .entry(item.id)
                .or_default()
                .push(Listing { price, count });
        }
    }
    items
}

/// Each item's listings as the row a full scan would upload.
fn rows(items: &BTreeMap<u64, Vec<Listing>>) -> Vec<PriceRow> {
    items
        .iter()
        .filter_map(|(id, listings)| {
            let row = summarize(listings.clone())?;
            Some((
                id.to_string(),
                row.min,
                row.market_value,
                row.quantity,
                row.auctions,
            ))
        })
        .collect()
}

/// Each item's listings as its order book at `scanned_at`, one offer per unit
/// price. The API names no sellers, so no offer has owners, as when the addon
/// uploads stock whose owner it does not know.
fn books(
    source: &Source,
    scanned_at: u64,
    items: &BTreeMap<u64, Vec<Listing>>,
) -> Vec<SellerSnapshot> {
    items
        .iter()
        .map(|(id, listings)| {
            let mut levels: BTreeMap<u64, u64> = BTreeMap::new();
            for listing in listings {
                *levels.entry(listing.price).or_default() += listing.count;
            }
            SellerSnapshot {
                realm: source.house.into(),
                faction: source.faction.into(),
                item_key: id.to_string(),
                scanned_at,
                offers: levels
                    .into_iter()
                    .map(|(unit_price, quantity)| SellerOffer {
                        unit_price,
                        quantity,
                        owners: vec![],
                        total_owners: 0,
                    })
                    .collect(),
            }
        })
        .collect()
}

/// Stores each book in place of its item's previous polled book. A polled
/// book's realm is its house, a name no shard reports, so `realm = house`
/// tells it apart from a player's upload, which is never replaced.
fn store_books(db: &mut Connection, books: &[SellerSnapshot]) -> Result<()> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    {
        let mut replace = tx.prepare("DELETE FROM seller_snapshots WHERE house=?1 AND realm=?1 AND faction=?2 AND item_key=?3 AND fingerprint<>?4")?;
        let mut insert = tx.prepare("INSERT INTO seller_snapshots (fingerprint,realm,faction,item_key,scanned_at,payload,house) VALUES (?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(fingerprint) DO NOTHING")?;
        for book in books {
            let fingerprint = book.fingerprint();
            replace.execute(params![
                book.realm,
                book.faction,
                book.item_key,
                fingerprint
            ])?;
            insert.execute(params![
                fingerprint,
                book.realm,
                book.faction,
                book.item_key,
                book.scanned_at as i64,
                serde_json::to_string(book)?,
                House::of(&book.realm)
            ])?;
        }
    }
    tx.commit()?;
    Ok(())
}

/// The plain item IDs priced in a polled house that have no name.
fn unnamed_items(db: &Connection) -> Result<BTreeSet<String>> {
    let mut select = db.prepare("SELECT item_key FROM latest_prices WHERE house=?1 AND faction=?2 AND item_key NOT GLOB '*[^0-9]*' AND item_key NOT IN (SELECT item_key FROM items)")?;
    let mut items = BTreeSet::new();
    for source in &SOURCES {
        for item in select.query_map(params![House::of(source.house), source.faction], |row| {
            row.get(0)
        })? {
            items.insert(item?);
        }
    }
    Ok(items)
}

struct Token {
    value: String,
    refresh_at: Instant,
}

/// Polls every house in `SOURCES` once per `poll_once`, stores each new
/// snapshot as a full scan and an order book per item, and then names the
/// items they price that have no name.
pub struct Poller {
    config: AuctionConfig,
    database: PathBuf,
    client: Client,
    token: Option<Token>,
}
impl Poller {
    pub fn new(config: AuctionConfig, database: PathBuf) -> Result<Self> {
        let client = Client::builder()
            .timeout(Duration::from_secs(60))
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        Ok(Self {
            config,
            database,
            client,
            token: None,
        })
    }
    pub fn run(mut self) {
        let sources: Vec<_> = SOURCES.iter().map(Source::to_string).collect();
        eprintln!(
            "battlenet auctions: polling {} now and at {AUCTION_POLL_MINUTE} minutes past each hour",
            sources.join(", ")
        );
        loop {
            self.poll_once();
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default();
            let next = next_minute_past_hour(now.as_secs(), AUCTION_POLL_MINUTE);
            std::thread::sleep(Duration::from_secs(next) - now);
        }
    }
    /// One pass over the houses. A house that fails is logged and the pass
    /// goes on with the next.
    pub fn poll_once(&mut self) {
        let mut db = match db::connect(&self.database) {
            Ok(db) => db,
            Err(error) => {
                eprintln!("battlenet auctions: database failed: {error:#}");
                return;
            }
        };
        for source in &SOURCES {
            match self.poll(&mut db, source) {
                Ok(Some((at, items))) => eprintln!(
                    "battlenet auctions: stored {source} snapshot {at} with {items} items"
                ),
                Ok(None) => {}
                Err(error) => eprintln!("battlenet auctions: {source} failed: {error:#}"),
            }
        }
        self.name_items(&db);
    }
    /// Names each unnamed item from the first of `NAME_SOURCES` that knows
    /// it, storing each name as it is found. The first failure ends the pass,
    /// and so does `naming_budget`. The next pass looks up whatever is still
    /// unnamed, including the items no namespace knows.
    fn name_items(&mut self, db: &Connection) {
        let deadline = Instant::now() + self.config.naming_budget;
        let mut named = [0; NAME_SOURCES.len()];
        let (mut nowhere, mut left) = (0, 0);
        let outcome = unnamed_items(db).and_then(|items| {
            'items: for (index, item) in items.iter().enumerate() {
                if Instant::now() >= deadline {
                    left = items.len() - index;
                    break;
                }
                for (count, (namespace, source)) in named.iter_mut().zip(NAME_SOURCES) {
                    if let Some((name, quality)) = self.item_name(namespace, item)? {
                        // A player's name stored during the lookup stays.
                        db.execute("INSERT INTO items (item_key,name,quality,source) VALUES (?1,?2,?3,?4) ON CONFLICT(item_key) DO NOTHING", params![item, name, quality, source])?;
                        *count += 1;
                        continue 'items;
                    }
                }
                nowhere += 1;
            }
            Ok(())
        });
        if let Err(error) = outcome {
            eprintln!("battlenet auctions: naming items failed: {error:#}");
        }
        if named.iter().any(|&count| count > 0) || left > 0 {
            let counts: Vec<_> = NAME_SOURCES
                .iter()
                .zip(named)
                .map(|((_, source), count)| format!("{count} items from {source}"))
                .collect();
            eprintln!(
                "battlenet auctions: named {}, {nowhere} found nowhere, {left} left for the next pass",
                counts.join(", ")
            );
        }
    }
    /// The item's name and quality in `namespace`; None when the namespace
    /// does not know the item or its quality.
    fn item_name(&mut self, namespace: &str, item: &str) -> Result<Option<(String, i64)>> {
        let url = self.config.item_url(namespace, item);
        let response = self.get(&url, None)?;
        if response.status() == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        let found: NamedItem = json(response, &url)?;
        Ok(QUALITIES
            .iter()
            .position(|quality| *quality == found.quality.r#type)
            .map(|quality| (found.name, quality as i64)))
    }
    fn poll(&mut self, db: &mut Connection, source: &Source) -> Result<Option<(u64, usize)>> {
        let stored: Option<i64> = db.query_row(
            "SELECT MAX(scanned_at) FROM scans WHERE house=?1 AND faction=?2 AND scanner=?3 AND scanned_at<=unixepoch()",
            params![source.house, source.faction, SCANNER],
            |row| row.get(0),
        )?;
        let stored = stored.and_then(|at| u64::try_from(at).ok());
        // Both lists carry their snapshot's time. A snapshot published between
        // the two requests would mix two snapshots into one scan, so the pair
        // is fetched once more, after a pause in case the two URLs' caches
        // turn over a few seconds apart.
        for attempt in 0..2 {
            if attempt > 0 {
                std::thread::sleep(self.config.retry_pause);
            }
            let Some((snapshot, regular)) = self.list(source, "", stored)? else {
                return Ok(None);
            };
            let Some((at, commodities)) = self.list(source, "/commodities", stored)? else {
                continue;
            };
            if at != snapshot {
                continue;
            }
            let items = listings(regular, commodities);
            // The books go first: when storing the scan fails after them, the
            // next poll fetches this snapshot again, while books missing
            // behind a stored scan would wait for the next snapshot.
            store_books(db, &books(source, snapshot, &items))?;
            let scan = ScanUpload {
                realm: source.house.into(),
                faction: source.faction.into(),
                region: REGION.into(),
                scanned_at: snapshot,
                mode: "replicate".into(),
                scanner: SCANNER.into(),
                build: String::new(),
                rows: rows(&items),
                items: BTreeMap::new(),
            };
            db::store_scan(db, &scan)?;
            return Ok(Some((snapshot, scan.rows.len())));
        }
        bail!("its two lists came from different snapshots twice")
    }
    /// One list of the house and the time of its snapshot; None when the
    /// snapshot is not newer than `since`.
    fn list<T: serde::de::DeserializeOwned>(
        &mut self,
        source: &Source,
        list: &str,
        since: Option<u64>,
    ) -> Result<Option<(u64, T)>> {
        let url = self.config.auctions_url(source, list);
        let response = self.get(&url, since)?;
        if response.status() == StatusCode::NOT_MODIFIED {
            return Ok(None);
        }
        ensure!(
            response.status().is_success(),
            "{url} answered {}",
            response.status()
        );
        let snapshot = response
            .headers()
            .get(LAST_MODIFIED)
            .and_then(|value| value.to_str().ok())
            .and_then(parse_http_date)
            .ok_or_else(|| anyhow!("{url} sent no valid Last-Modified"))?;
        if since.is_some_and(|since| since >= snapshot) {
            return Ok(None);
        }
        Ok(Some((snapshot, json(response, &url)?)))
    }
    /// GETs `url` with the cached token, and once more with a new token when
    /// Battle.net refuses the cached one.
    fn get(&mut self, url: &str, since: Option<u64>) -> Result<Response> {
        let response = self.send(url, since)?;
        if response.status() != StatusCode::UNAUTHORIZED {
            return Ok(response);
        }
        self.token = None;
        self.send(url, since)
    }
    fn send(&mut self, url: &str, since: Option<u64>) -> Result<Response> {
        let mut request = self.client.get(url).bearer_auth(self.bearer()?);
        if let Some(since) = since {
            request = request.header(IF_MODIFIED_SINCE, http_date(since));
        }
        Ok(request.send()?)
    }
    fn bearer(&mut self) -> Result<String> {
        if let Some(token) = &self.token
            && Instant::now() < token.refresh_at
        {
            return Ok(token.value.clone());
        }
        #[derive(Deserialize)]
        struct Granted {
            access_token: String,
            expires_in: u64,
        }
        let response = self
            .client
            .post(&self.config.token_endpoint)
            .basic_auth(&self.config.client_id, Some(&self.config.client_secret))
            .form(&[("grant_type", "client_credentials")])
            .send()?;
        let granted: Granted = json(response, "the token endpoint")?;
        ensure!(
            !granted.access_token.is_empty(),
            "the token endpoint granted an empty token"
        );
        let lifetime = Duration::from_secs(granted.expires_in.saturating_sub(TOKEN_MARGIN));
        self.token = Some(Token {
            value: granted.access_token.clone(),
            refresh_at: Instant::now() + lifetime,
        });
        Ok(granted.access_token)
    }
}
fn json<T: serde::de::DeserializeOwned>(response: Response, what: &str) -> Result<T> {
    let status = response.status();
    ensure!(status.is_success(), "{what} answered {status}");
    let mut body = Vec::new();
    response.take(MAX_BODY + 1).read_to_end(&mut body)?;
    ensure!(
        body.len() as u64 <= MAX_BODY,
        "{what} sent more than {MAX_BODY} bytes"
    );
    serde_json::from_slice(&body).with_context(|| format!("{what} sent unexpected JSON"))
}

const WEEKDAYS: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/// Unix seconds as an IMF-fixdate, `Fri, 06 Nov 2026 09:17:22 GMT`.
fn http_date(at: u64) -> String {
    let days = (at / 86400) as i64;
    let seconds = at % 86400;
    let (year, month, day) = civil(days);
    format!(
        "{}, {day:02} {} {year} {:02}:{:02}:{:02} GMT",
        WEEKDAYS[(days + 3).rem_euclid(7) as usize],
        MONTHS[month as usize - 1],
        seconds / 3600,
        seconds / 60 % 60,
        seconds % 60
    )
}
/// Unix seconds of an HTTP date in the IMF-fixdate layout. Battle.net writes
/// days below 10 with one digit, `Fri, 6 Nov 2026 09:17:22 GMT`, so both
/// widths parse. The weekday is not checked.
fn parse_http_date(text: &str) -> Option<u64> {
    let [_, day, month, year, time, "GMT"] = text.split_whitespace().collect::<Vec<_>>()[..] else {
        return None;
    };
    let number = |s: &str, width: std::ops::RangeInclusive<usize>| {
        (width.contains(&s.len()) && s.bytes().all(|b| b.is_ascii_digit()))
            .then(|| s.parse::<i64>().ok())
            .flatten()
    };
    let day = number(day, 1..=2)?;
    let month = MONTHS.iter().position(|m| *m == month)? as i64 + 1;
    let year = number(year, 4..=4)?;
    let [hour, minute, second] = time.split(':').collect::<Vec<_>>()[..] else {
        return None;
    };
    let (hour, minute, second) = (
        number(hour, 2..=2)?,
        number(minute, 2..=2)?,
        number(second, 2..=2)?,
    );
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let days = days_from_civil(year, month, day);
    if civil(days) != (year, month, day) {
        return None;
    }
    u64::try_from(days * 86400 + hour * 3600 + minute * 60 + second).ok()
}
// Howard Hinnant's civil calendar algorithms, for the proleptic Gregorian
// calendar that HTTP dates use.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let day_of_year = (153 * ((month + 9) % 12) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146097 + day_of_era - 719468
}
fn civil(days: i64) -> (i64, i64, i64) {
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let day_of_era = z.rem_euclid(146097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * shifted_month + 2) / 5 + 1;
    let month = if shifted_month < 10 {
        shifted_month + 3
    } else {
        shifted_month - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn convert(regular: &str, commodities: &str) -> Vec<PriceRow> {
        rows(&listings(
            serde_json::from_str(regular).unwrap(),
            serde_json::from_str(commodities).unwrap(),
        ))
    }

    // The market values are what addon/Goldbook/Stats.lua computes for the
    // same listings.
    #[test]
    fn listings_become_the_rows_a_full_scan_would_upload() {
        let regular = r#"{"_links":{},"id":113,"name":"Horde","auctions":[
            {"id":1,"item":{"id":2589},"buyout":120,"quantity":1,"time_left":"LONG"},
            {"id":2,"item":{"id":2589},"buyout":100,"quantity":1,"time_left":"LONG"},
            {"id":3,"item":{"id":2589},"buyout":101,"quantity":1,"time_left":"SHORT"},
            {"id":4,"item":{"id":2589},"buyout":400,"bid":350,"quantity":1,"time_left":"LONG"},
            {"id":5,"item":{"id":15477,"bonus_lists":[12725]},"buyout":300,"quantity":1,"time_left":"LONG"},
            {"id":6,"item":{"id":15477},"buyout":500,"quantity":1,"time_left":"LONG"},
            {"id":7,"item":{"id":9999},"bid":50,"quantity":1,"time_left":"LONG"},
            {"id":8,"item":{"id":4306,"context":3,"modifiers":[{"type":28,"value":1}]},"buyout":1001,"quantity":2,"time_left":"LONG"},
            {"id":9,"item":{"id":4306,"bonus_lists":[]},"buyout":480,"quantity":1,"time_left":"LONG"}
        ]}"#;
        let commodities = r#"{"_links":{},"auctions":[
            {"id":10,"item":{"id":4537},"quantity":20,"unit_price":50,"time_left":"VERY_LONG"},
            {"id":11,"item":{"id":4537},"quantity":5,"unit_price":45,"time_left":"SHORT"},
            {"id":12,"item":{"id":4537},"quantity":100,"unit_price":80,"time_left":"LONG"},
            {"id":13,"item":{"id":2592},"quantity":3,"unit_price":0,"time_left":"LONG"}
        ]}"#;
        assert_eq!(
            convert(regular, commodities),
            [
                ("2589".into(), 100, 101, 4, 4),
                ("4306".into(), 480, 480, 3, 2),
                ("4537".into(), 45, 50, 125, 3),
                ("15477".into(), 500, 500, 1, 1),
            ]
        );
    }

    #[test]
    fn an_empty_house_has_no_rows() {
        assert_eq!(
            convert(
                r#"{"_links":{},"id":112,"name":"Alliance"}"#,
                r#"{"_links":{}}"#
            ),
            []
        );
    }

    #[test]
    fn eu_pvp_and_eu_pve_are_polled_for_both_factions_and_neutral() {
        let config = AuctionConfig::parse("1", "id", "secret").unwrap().unwrap();
        let polled: Vec<_> = SOURCES
            .iter()
            .map(|source| {
                assert_eq!(crate::house::House::of(source.house).as_str(), source.house);
                (
                    source.to_string(),
                    config.auctions_url(source, "/commodities"),
                )
            })
            .collect();
        assert_eq!(
            polled,
            [
                (
                    "EU PvP/Horde (house 113)".to_owned(),
                    "https://eu.api.blizzard.com/data/wow/ruleset/1/auctions/113/commodities?namespace=dynamic-forever-eu".to_owned()
                ),
                (
                    "EU PvP/Alliance (house 110)".to_owned(),
                    "https://eu.api.blizzard.com/data/wow/ruleset/1/auctions/110/commodities?namespace=dynamic-forever-eu".to_owned()
                ),
                (
                    "EU PvE/Horde (house 114)".to_owned(),
                    "https://eu.api.blizzard.com/data/wow/ruleset/1/auctions/114/commodities?namespace=dynamic-forever-eu".to_owned()
                ),
                (
                    "EU PvE/Alliance (house 111)".to_owned(),
                    "https://eu.api.blizzard.com/data/wow/ruleset/1/auctions/111/commodities?namespace=dynamic-forever-eu".to_owned()
                ),
                (
                    "EU PvP/Neutral (house 116)".to_owned(),
                    "https://eu.api.blizzard.com/data/wow/ruleset/1/auctions/116/commodities?namespace=dynamic-forever-eu".to_owned()
                ),
                (
                    "EU PvE/Neutral (house 117)".to_owned(),
                    "https://eu.api.blizzard.com/data/wow/ruleset/1/auctions/117/commodities?namespace=dynamic-forever-eu".to_owned()
                ),
            ]
        );
    }

    #[test]
    fn polling_is_off_unless_switched_on() {
        for switch in ["", "  ", "0"] {
            assert!(AuctionConfig::parse(switch, "", "").unwrap().is_none());
            assert!(
                AuctionConfig::parse(switch, "id", "secret")
                    .unwrap()
                    .is_none()
            );
        }
        assert!(
            AuctionConfig::parse(" 1 ", "id", "secret")
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn an_invalid_switch_stops_the_server() {
        for (switch, id, secret, error) in [
            (
                "1",
                "",
                "",
                "GOLDBOOK_BATTLENET_AUCTIONS needs BNET_CLIENT_ID and BNET_CLIENT_SECRET",
            ),
            (
                "1",
                "id",
                " ",
                "GOLDBOOK_BATTLENET_AUCTIONS needs BNET_CLIENT_ID and BNET_CLIENT_SECRET",
            ),
            (
                "true",
                "id",
                "secret",
                "GOLDBOOK_BATTLENET_AUCTIONS is \"true\"; set it to 1 for on, or 0 for off",
            ),
            (
                "EU PvP/Horde=113",
                "id",
                "secret",
                "GOLDBOOK_BATTLENET_AUCTIONS is \"EU PvP/Horde=113\"; set it to 1 for on, or 0 for off",
            ),
        ] {
            let refused = AuctionConfig::parse(switch, id, secret).unwrap_err();
            assert_eq!(format!("{refused:#}"), error, "{switch}");
        }
    }

    #[test]
    fn http_dates_read_battlenets_layout_and_write_imf_fixdates() {
        assert_eq!(
            parse_http_date("Fri, 6 Nov 2026 09:17:22 GMT"),
            Some(1793956642)
        );
        assert_eq!(
            parse_http_date("Fri, 06 Nov 2026 09:17:22 GMT"),
            Some(1793956642)
        );
        assert_eq!(
            parse_http_date("Thu, 29 Feb 2024 23:59:59 GMT"),
            Some(1709251199)
        );
        assert_eq!(http_date(1793956642), "Fri, 06 Nov 2026 09:17:22 GMT");
        assert_eq!(http_date(1709251199), "Thu, 29 Feb 2024 23:59:59 GMT");
        assert_eq!(http_date(0), "Thu, 01 Jan 1970 00:00:00 GMT");
        for invalid in [
            "",
            "Fri, 6 Nov 2026 09:17:22",
            "Fri, 6 Nov 2026 09:17:22 UTC",
            "Fri, 31 Nov 2026 09:17:22 GMT",
            "Fri, 29 Feb 2026 09:17:22 GMT",
            "Fri, 6 Noe 2026 09:17:22 GMT",
            "Fri, 6 Nov 2026 24:00:00 GMT",
            "Fri, 6 Nov 2026 9:17:22 GMT",
            "Fri, 006 Nov 2026 09:17:22 GMT",
            "Friday, 06-Nov-26 09:17:22 GMT",
        ] {
            assert_eq!(parse_http_date(invalid), None, "{invalid}");
        }
    }
}
