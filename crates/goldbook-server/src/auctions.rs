//! Auction snapshots of WoW Forever houses from the Battle.net Game Data API,
//! stored as full scans so that they reach clients like a player's upload.
//!
//! `GOLDBOOK_BATTLENET_HOUSES` names the houses to poll; unset, nothing here
//! runs. docs/ah-api/README.md records what the API returns.

use crate::{db, house::House};
use anyhow::{Context, Result, anyhow, bail, ensure};
use goldbook_core::{Listing, PriceRow, ScanUpload, summarize};
use reqwest::{
    StatusCode,
    blocking::{Client, Response},
    header::{IF_MODIFIED_SINCE, LAST_MODIFIED},
};
use rusqlite::{Connection, params};
use serde::Deserialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    io::Read,
    path::PathBuf,
    time::{Duration, Instant},
};

const SCANNER: &str = "Battle.net";
const INTERVAL: Duration = Duration::from_secs(600);
// The ruleset in the URL does not select the market, but each URL serves its
// own cached copy, so every snapshot of a house comes through the same one.
const RULESET: u32 = 1;
const MAX_BODY: u64 = 128 * 1024 * 1024;
const TOKEN_MARGIN: u64 = 300;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Region {
    Eu,
    Us,
}
impl Region {
    fn of(house: &str) -> Option<Self> {
        match house.split_whitespace().next()? {
            "EU" => Some(Self::Eu),
            "US" => Some(Self::Us),
            _ => None,
        }
    }
    fn label(self) -> &'static str {
        match self {
            Self::Eu => "EU",
            Self::Us => "US",
        }
    }
    fn namespace(self) -> &'static str {
        match self {
            Self::Eu => "dynamic-forever-eu",
            Self::Us => "dynamic-forever-us",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Faction {
    Alliance,
    Horde,
}
impl Faction {
    fn as_str(self) -> &'static str {
        match self {
            Self::Alliance => "Alliance",
            Self::Horde => "Horde",
        }
    }
}

/// One server house and faction, and the API house that lists its auctions.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Source {
    house: House,
    faction: Faction,
    region: Region,
    house_id: u32,
}
impl std::fmt::Display for Source {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(
            f,
            "{}/{} (house {})",
            self.house.as_str(),
            self.faction.as_str(),
            self.house_id
        )
    }
}

#[derive(Clone, Debug)]
pub struct AuctionConfig {
    client_id: String,
    client_secret: String,
    sources: Vec<Source>,
    // Tests point these at a loopback server.
    pub token_endpoint: String,
    pub eu_api: String,
    pub us_api: String,
}
impl AuctionConfig {
    pub(crate) fn from_env() -> Result<Option<Self>> {
        let [houses, id, secret] = [
            "GOLDBOOK_BATTLENET_HOUSES",
            "BNET_CLIENT_ID",
            "BNET_CLIENT_SECRET",
        ]
        .map(|name| std::env::var(name).unwrap_or_default());
        Self::parse(&houses, &id, &secret)
    }
    /// The houses to poll, from `<house>/<faction>=<API house ID>` entries
    /// such as `EU PvP/Horde=113,EU PvP/Alliance=110`. None when `houses` is
    /// blank.
    pub fn parse(houses: &str, client_id: &str, client_secret: &str) -> Result<Option<Self>> {
        if houses.trim().is_empty() {
            return Ok(None);
        }
        ensure!(
            !client_id.trim().is_empty() && !client_secret.trim().is_empty(),
            "GOLDBOOK_BATTLENET_HOUSES needs BNET_CLIENT_ID and BNET_CLIENT_SECRET"
        );
        let mut sources = Vec::new();
        let mut seen = BTreeSet::new();
        for entry in crate::split(houses) {
            let source = source(entry)
                .with_context(|| format!("invalid GOLDBOOK_BATTLENET_HOUSES entry {entry:?}"))?;
            ensure!(
                seen.insert((source.house.as_str().to_owned(), source.faction)),
                "GOLDBOOK_BATTLENET_HOUSES names {}/{} twice",
                source.house.as_str(),
                source.faction.as_str()
            );
            sources.push(source);
        }
        ensure!(
            !sources.is_empty(),
            "GOLDBOOK_BATTLENET_HOUSES names no house"
        );
        Ok(Some(Self {
            client_id: client_id.into(),
            client_secret: client_secret.into(),
            sources,
            token_endpoint: "https://oauth.battle.net/token".into(),
            eu_api: "https://eu.api.blizzard.com".into(),
            us_api: "https://us.api.blizzard.com".into(),
        }))
    }
    fn auctions_url(&self, source: &Source, list: &str) -> String {
        let api = match source.region {
            Region::Eu => &self.eu_api,
            Region::Us => &self.us_api,
        };
        format!(
            "{}/data/wow/ruleset/{RULESET}/auctions/{}{list}?namespace={}",
            api.trim_end_matches('/'),
            source.house_id,
            source.region.namespace()
        )
    }
}
fn source(entry: &str) -> Result<Source> {
    let (market, id) = entry
        .rsplit_once('=')
        .ok_or_else(|| anyhow!("expected <house>/<faction>=<API house ID>"))?;
    let (name, faction) = market
        .rsplit_once('/')
        .ok_or_else(|| anyhow!("expected <house>/<faction>=<API house ID>"))?;
    let name = name.trim();
    let house = House::of(name);
    ensure!(
        !name.is_empty() && house.as_str() == name,
        "{name:?} is not a house name; did you mean {:?}?",
        house.as_str()
    );
    let region =
        Region::of(name).ok_or_else(|| anyhow!("{name:?} does not start with EU or US"))?;
    let faction = match faction.trim() {
        "Alliance" => Faction::Alliance,
        "Horde" => Faction::Horde,
        other => bail!("faction {other:?} is not Alliance or Horde"),
    };
    let house_id = id
        .trim()
        .parse()
        .map_err(|_| anyhow!("API house ID {:?} is not a number", id.trim()))?;
    Ok(Source {
        house,
        faction,
        region,
        house_id,
    })
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

/// A house's two lists as scan rows, keyed by plain item ID. The API's bonus
/// IDs are not the addon's suffixes, so a variant with `bonus_lists` would mix
/// its price into the base item's; it is left out, as is a listing without a
/// buyout.
fn rows(
    regular: Auctions<RegularListing>,
    commodities: Auctions<CommodityListing>,
) -> Vec<PriceRow> {
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
        .into_iter()
        .filter_map(|(id, listings)| {
            let row = summarize(listings)?;
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

struct Token {
    value: String,
    refresh_at: Instant,
}

/// Polls every configured house once per `poll_once`, and stores each new
/// snapshot as a full scan.
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
        let sources: Vec<_> = self.config.sources.iter().map(Source::to_string).collect();
        eprintln!(
            "battlenet auctions: polling {} every {} minutes",
            sources.join(", "),
            INTERVAL.as_secs() / 60
        );
        loop {
            self.poll_once();
            std::thread::sleep(INTERVAL);
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
        for source in self.config.sources.clone() {
            match self.poll(&mut db, &source) {
                Ok(Some((at, items))) => eprintln!(
                    "battlenet auctions: stored {source} snapshot {at} with {items} items"
                ),
                Ok(None) => {}
                Err(error) => eprintln!("battlenet auctions: {source} failed: {error:#}"),
            }
        }
    }
    fn poll(&mut self, db: &mut Connection, source: &Source) -> Result<Option<(u64, usize)>> {
        let stored: Option<i64> = db.query_row(
            "SELECT MAX(scanned_at) FROM scans WHERE house=?1 AND faction=?2 AND scanner=?3",
            params![source.house, source.faction.as_str(), SCANNER],
            |row| row.get(0),
        )?;
        let stored = stored.and_then(|at| u64::try_from(at).ok());
        let url = self.config.auctions_url(source, "");
        let response = self.get(&url, stored)?;
        if response.status() == StatusCode::NOT_MODIFIED {
            return Ok(None);
        }
        let snapshot = response
            .headers()
            .get(LAST_MODIFIED)
            .and_then(|value| value.to_str().ok())
            .and_then(parse_http_date)
            .ok_or_else(|| anyhow!("{url} sent no valid Last-Modified"))?;
        if stored.is_some_and(|stored| stored >= snapshot) {
            return Ok(None);
        }
        let regular = json(response, &url)?;
        let url = self.config.auctions_url(source, "/commodities");
        let commodities = json(self.get(&url, None)?, &url)?;
        let scan = ScanUpload {
            realm: source.house.as_str().into(),
            faction: source.faction.as_str().into(),
            region: source.region.label().into(),
            scanned_at: snapshot,
            mode: "replicate".into(),
            scanner: SCANNER.into(),
            build: String::new(),
            rows: rows(regular, commodities),
            items: BTreeMap::new(),
        };
        db::store_scan(db, &scan)?;
        Ok(Some((snapshot, scan.rows.len())))
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
        rows(
            serde_json::from_str(regular).unwrap(),
            serde_json::from_str(commodities).unwrap(),
        )
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
    fn houses_parse_into_sources() {
        let config = AuctionConfig::parse(
            " EU PvP/Horde=113, EU PvP/Alliance = 110 ,US Normal/Horde=124,",
            "id",
            "secret",
        )
        .unwrap()
        .unwrap();
        let polled: Vec<_> = config
            .sources
            .iter()
            .map(|source| {
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
                    "US Normal/Horde (house 124)".to_owned(),
                    "https://us.api.blizzard.com/data/wow/ruleset/1/auctions/124/commodities?namespace=dynamic-forever-us".to_owned()
                ),
            ]
        );
    }

    #[test]
    fn polling_is_off_unless_houses_are_named() {
        for houses in ["", "  "] {
            assert!(AuctionConfig::parse(houses, "", "").unwrap().is_none());
            assert!(
                AuctionConfig::parse(houses, "id", "secret")
                    .unwrap()
                    .is_none()
            );
        }
    }

    #[test]
    fn invalid_houses_stop_the_server() {
        for (houses, id, secret, error) in [
            (
                "EU PvP/Horde=113",
                "",
                "",
                "GOLDBOOK_BATTLENET_HOUSES needs BNET_CLIENT_ID and BNET_CLIENT_SECRET",
            ),
            (
                "EU PvP/Horde=113",
                "id",
                " ",
                "GOLDBOOK_BATTLENET_HOUSES needs BNET_CLIENT_ID and BNET_CLIENT_SECRET",
            ),
            (
                "EU PvP/Horde",
                "id",
                "secret",
                "invalid GOLDBOOK_BATTLENET_HOUSES entry \"EU PvP/Horde\": expected <house>/<faction>=<API house ID>",
            ),
            (
                "EU PvP=113",
                "id",
                "secret",
                "invalid GOLDBOOK_BATTLENET_HOUSES entry \"EU PvP=113\": expected <house>/<faction>=<API house ID>",
            ),
            (
                "CAMWOWEU4Realm8PvP/Horde=113",
                "id",
                "secret",
                "invalid GOLDBOOK_BATTLENET_HOUSES entry \"CAMWOWEU4Realm8PvP/Horde=113\": \"CAMWOWEU4Realm8PvP\" is not a house name; did you mean \"EU PvP\"?",
            ),
            (
                "/Horde=113",
                "id",
                "secret",
                "invalid GOLDBOOK_BATTLENET_HOUSES entry \"/Horde=113\": \"\" is not a house name; did you mean \"\"?",
            ),
            (
                "Faramon/Horde=113",
                "id",
                "secret",
                "invalid GOLDBOOK_BATTLENET_HOUSES entry \"Faramon/Horde=113\": \"Faramon\" does not start with EU or US",
            ),
            (
                "KR PvP/Horde=113",
                "id",
                "secret",
                "invalid GOLDBOOK_BATTLENET_HOUSES entry \"KR PvP/Horde=113\": \"KR PvP\" does not start with EU or US",
            ),
            (
                "EU PvP/Neutral=116",
                "id",
                "secret",
                "invalid GOLDBOOK_BATTLENET_HOUSES entry \"EU PvP/Neutral=116\": faction \"Neutral\" is not Alliance or Horde",
            ),
            (
                "EU PvP/horde=113",
                "id",
                "secret",
                "invalid GOLDBOOK_BATTLENET_HOUSES entry \"EU PvP/horde=113\": faction \"horde\" is not Alliance or Horde",
            ),
            (
                "EU PvP/Horde=house",
                "id",
                "secret",
                "invalid GOLDBOOK_BATTLENET_HOUSES entry \"EU PvP/Horde=house\": API house ID \"house\" is not a number",
            ),
            (
                "EU PvP/Horde=113,EU PvP/Horde=114",
                "id",
                "secret",
                "GOLDBOOK_BATTLENET_HOUSES names EU PvP/Horde twice",
            ),
            (
                " , ",
                "id",
                "secret",
                "GOLDBOOK_BATTLENET_HOUSES names no house",
            ),
        ] {
            let refused = AuctionConfig::parse(houses, id, secret).unwrap_err();
            assert_eq!(format!("{refused:#}"), error, "{houses}");
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
