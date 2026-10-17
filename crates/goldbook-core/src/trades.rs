use crate::{MAX_SAFE_INTEGER, count, field, integer, item_key, object, text};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// At most this many trades travel in one account upload: 50 characters with
/// the addon's 1,000 each.
pub const MAX_TRADES: usize = 50_000;

/// Every side an entry can have, with the lowest price it may book. A player
/// trade spreads its gold over the items in it, so an item there can go for 0.
const SIDES: [(&str, u64); 21] = [
    ("sell", 1),
    ("buy", 1),
    ("vendor", 1),
    ("merchant", 1),
    ("tradeSell", 0),
    ("tradeBuy", 0),
    ("tradeIn", 1),
    ("tradeOut", 1),
    ("mailIn", 1),
    ("mailOut", 1),
    ("cod", 1),
    ("quest", 1),
    ("loot", 1),
    ("repair", 1),
    ("postage", 1),
    ("deposit", 1),
    ("travel", 1),
    ("training", 1),
    ("respec", 1),
    ("otherIn", 1),
    ("otherOut", 1),
];

/// A movement of gold as the addon booked it. `side` says what kind: goods
/// sold or bought at the auction house, from a vendor or merchant, in a player
/// trade or by cash on delivery, or gold alone, such as a quest reward, a
/// repair bill or gold sent by mail. `item` names the goods, or describes a
/// movement of gold alone. `price` is the whole stack's and never negative;
/// the side gives its direction. `fee` is the auction house cut, 0 for
/// anything but an auction sale. `party` is the other player of a trade or a
/// mail.
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
    /// Left out when there is none, so that such an entry uploads as before.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub party: Option<String>,
}

pub fn parse_trade(v: &Value, at: &str) -> Result<Trade, String> {
    let t = object(v, at)?;
    let time = integer(field(t, "at"), 1_000_000_000, MAX_SAFE_INTEGER)
        .ok_or_else(|| format!("{at}.at must be a unix time"))?;
    let (side, lowest) = field(t, "side")
        .as_str()
        .and_then(|s| SIDES.into_iter().find(|(side, _)| *side == s))
        .ok_or_else(|| {
            let sides: Vec<_> = SIDES.iter().map(|(side, _)| *side).collect();
            format!("{at}.side must be one of {}", sides.join(", "))
        })?;
    let item_key = match t.get("itemKey") {
        None | Some(Value::Null) => None,
        Some(v) => Some(item_key(v, &format!("{at}.itemKey"))?),
    };
    let units = integer(field(t, "count"), 1, MAX_SAFE_INTEGER)
        .ok_or_else(|| format!("{at}.count must be a positive integer"))?;
    let price = integer(field(t, "price"), lowest, MAX_SAFE_INTEGER).ok_or_else(|| {
        let kind = if lowest == 0 {
            "non-negative"
        } else {
            "positive"
        };
        format!("{at}.price must be a {kind} integer")
    })?;
    let fee = count(field(t, "fee"), &format!("{at}.fee"))?;
    if fee > price || (side != "sell" && fee > 0) {
        return Err(format!(
            "{at}.fee must not exceed the price, and only an auction sale has one"
        ));
    }
    let party = match t.get("party") {
        None | Some(Value::Null) => None,
        Some(v) => Some(text(v, &format!("{at}.party"), 1, 64)?),
    };
    Ok(Trade {
        name: text(field(t, "name"), &format!("{at}.name"), 1, 64)?,
        realm: text(field(t, "realm"), &format!("{at}.realm"), 1, 64)?,
        at: time,
        side: side.to_owned(),
        item: text(field(t, "item"), &format!("{at}.item"), 1, 200)?,
        item_key,
        count: units,
        price,
        fee,
        party,
    })
}
