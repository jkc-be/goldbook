use crate::{MAX_SAFE_INTEGER, count, field, integer, item_key, object, text};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// At most this many trades travel in one account upload: 50 characters with
/// the addon's 1,000 each.
pub const MAX_TRADES: usize = 50_000;

/// A trade as the addon booked it: an auction house sale ("sell") or
/// purchase ("buy") from the mailbox, or a sale to a vendor ("vendor") from
/// the merchant's buyback list. `price` is the whole stack's; `fee` is the
/// auction house cut, 0 for anything but an auction sale.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Trade {
    pub name: String,
    pub realm: String,
    pub at: u64,
    pub side: String,
    pub item: String,
    pub item_key: Option<String>,
    pub count: u64,
    pub price: u64,
    pub fee: u64,
}

pub fn parse_trade(v: &Value, at: &str) -> Result<Trade, String> {
    let t = object(v, at)?;
    let time = integer(field(t, "at"), 1_000_000_000, MAX_SAFE_INTEGER)
        .ok_or_else(|| format!("{at}.at must be a unix time"))?;
    let side = field(t, "side")
        .as_str()
        .filter(|s| ["buy", "sell", "vendor"].contains(s))
        .ok_or_else(|| format!("{at}.side must be one of buy, sell, vendor"))?
        .to_owned();
    let item_key = match t.get("itemKey") {
        None | Some(Value::Null) => None,
        Some(v) => Some(item_key(v, &format!("{at}.itemKey"))?),
    };
    let units = integer(field(t, "count"), 1, MAX_SAFE_INTEGER)
        .ok_or_else(|| format!("{at}.count must be a positive integer"))?;
    let price = integer(field(t, "price"), 1, MAX_SAFE_INTEGER)
        .ok_or_else(|| format!("{at}.price must be a positive integer"))?;
    let fee = count(field(t, "fee"), &format!("{at}.fee"))?;
    if fee > price || (side != "sell" && fee > 0) {
        return Err(format!(
            "{at}.fee must not exceed the price, and only an auction sale has one"
        ));
    }
    Ok(Trade {
        name: text(field(t, "name"), &format!("{at}.name"), 1, 64)?,
        realm: text(field(t, "realm"), &format!("{at}.realm"), 1, 64)?,
        at: time,
        side,
        item: text(field(t, "item"), &format!("{at}.item"), 1, 200)?,
        item_key,
        count: units,
        price,
        fee,
    })
}
