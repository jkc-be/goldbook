//! The addon's buying advice of addon/Goldbook/Advisor.lua, for the prices
//! the server stores.

use serde::Serialize;

const AH_CUT: f64 = 0.05;
const DEAL_RATIO: f64 = 0.7;
const MIN_HISTORY: usize = 3;
const MOVER_MIN_PRICE: u64 = 100;

/// Goods merchants sell without limit: drinks, spices, thread, vials, flux,
/// dyes, trade supplies, class reagents and fishing supplies. This is
/// MERCHANT_GOODS of addon/Goldbook/Database.lua. The addon also learns what
/// the merchants a player visits sell, which the server never sees.
#[rustfmt::skip]
const MERCHANT_GOODS: [u64; 42] = [
    159, 1179, 2678, 2692, 3713, 4289,
    2320, 2321, 4291, 8343, 14341,
    3371, 3372, 8925,
    2880, 3466, 3857, 4470, 4471, 6217,
    2324, 2604, 2605, 4340, 4341, 4342, 6260,
    5140, 17020, 17026, 17029, 17030, 17031, 17034, 17035, 17036, 17037, 17038, 17056,
    6256, 6529, 6530,
];

/// An item of the newest scan as the addon keeps it after merging the
/// server's export (docs/server-data.md), which has no ladder of price levels.
#[derive(Debug, Clone, PartialEq)]
pub struct PriceRecord {
    /// The newest scan's lowest buyout.
    pub min: u64,
    /// The newest scan's market value, when that scan was a full one.
    pub market: Option<u64>,
    /// The lowest buyout of each of the last 14 days the item was seen,
    /// oldest first. The last is the newest scan's day.
    pub days: Vec<u64>,
}

/// An item to buy now and sell again on the auction house at `sell`, which
/// makes `profit` per unit after the auction house's cut.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Flip {
    pub sell: u64,
    pub profit: u64,
}

/// An item whose lowest buyout moved by `change` percent from `before`, the
/// lowest buyout of the day before.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Mover {
    pub before: u64,
    pub change: f64,
}

/// Stats.Median, which rounds the mean of the middle two up.
pub fn median(values: &[u64]) -> Option<u64> {
    let mut sorted = values.to_vec();
    sorted.sort_unstable();
    let middle = sorted.len().div_ceil(2);
    match sorted.len() {
        0 => None,
        n if n % 2 == 1 => Some(sorted[middle - 1]),
        _ => Some((sorted[middle - 1] + sorted[middle]).div_ceil(2)),
    }
}

/// The lower of the market value and the usual price of the days before the
/// newest, so that a bargain does not lower the bar it is measured against.
fn resale(record: &PriceRecord) -> Option<u64> {
    let earlier = &record.days[..record.days.len().saturating_sub(1)];
    let earlier = (earlier.len() >= MIN_HISTORY)
        .then(|| median(earlier))
        .flatten();
    match (record.market, earlier) {
        (Some(market), Some(earlier)) => Some(market.min(earlier)),
        (market, earlier) => market.or(earlier),
    }
}

/// The auction half of Advisor.Deal. An item merchants sell (`stocked`) is no
/// flip: its auction price is paid only by buyers who do not know that.
pub fn flip(record: &PriceRecord, stocked: bool) -> Option<Flip> {
    if stocked {
        return None;
    }
    let sell = resale(record)?;
    (record.min as f64 <= sell as f64 * DEAL_RATIO).then(|| Flip {
        sell,
        profit: (sell as f64 * (1.0 - AH_CUT)).floor() as u64 - record.min,
    })
}

/// Advisor.Movers for one item. Prices under a silver on both days are noise.
pub fn mover(record: &PriceRecord) -> Option<Mover> {
    let before = *record.days.iter().rev().nth(1)?;
    if before == record.min || before.max(record.min) < MOVER_MIN_PRICE {
        return None;
    }
    let change = (record.min as f64 - before as f64) / before as f64 * 1000.0;
    Some(Mover {
        before,
        change: (change + 0.5).floor() / 10.0,
    })
}

pub fn merchant_sells(item_key: &str) -> bool {
    let id = item_key.split(':').next().unwrap_or("");
    id.parse().is_ok_and(|id: u64| MERCHANT_GOODS.contains(&id))
}
