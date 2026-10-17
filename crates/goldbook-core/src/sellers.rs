use crate::{MAX_SAFE_INTEGER, count, field, item_key, list, object, sha256, text};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SellerOffer {
    pub unit_price: u64,
    pub quantity: u64,
    pub owners: Vec<String>,
    pub total_owners: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SellerSnapshot {
    pub realm: String,
    pub faction: String,
    pub item_key: String,
    pub scanned_at: u64,
    pub offers: Vec<SellerOffer>,
}

pub fn parse_seller_snapshot(value: &Value) -> Result<SellerSnapshot, String> {
    let s = object(value, "seller snapshot")?;
    let mut offers = Vec::new();
    let mut quantity = 0_u64;
    for (i, offer) in list(field(s, "offers"), "offers", 200_000)?
        .iter()
        .enumerate()
    {
        let at = format!("offers[{i}]");
        let offer = object(offer, &at)?;
        let unit_price = count(field(offer, "unitPrice"), &format!("{at}.unitPrice"))?;
        let units = count(field(offer, "quantity"), &format!("{at}.quantity"))?;
        if unit_price == 0 || units == 0 {
            return Err(format!("{at} price and quantity must be positive"));
        }
        quantity = quantity
            .checked_add(units)
            .filter(|n| *n <= MAX_SAFE_INTEGER)
            .ok_or("total quantity exceeds the safe integer limit")?;
        let owners = list(field(offer, "owners"), &format!("{at}.owners"), 100)?
            .iter()
            .map(|name| text(name, &format!("{at} owner"), 1, 128))
            .collect::<Result<BTreeSet<_>, _>>()?
            .into_iter()
            .collect::<Vec<_>>();
        let total_owners = count(field(offer, "totalOwners"), &format!("{at}.totalOwners"))?;
        if total_owners < owners.len() as u64 {
            return Err(format!(
                "{at}.totalOwners is smaller than the named owner count"
            ));
        }
        offers.push(SellerOffer {
            unit_price,
            quantity: units,
            owners,
            total_owners,
        });
    }
    offers.sort();
    let scanned_at = count(field(s, "scannedAt"), "scannedAt")?;
    if scanned_at == 0 {
        return Err("scannedAt must be a unix timestamp".into());
    }
    Ok(SellerSnapshot {
        realm: text(field(s, "realm"), "realm", 1, 64)?,
        faction: text(field(s, "faction"), "faction", 1, 64)?,
        item_key: item_key(field(s, "itemKey"), "itemKey")?,
        scanned_at,
        offers,
    })
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SellerShare {
    pub name: String,
    pub quantity: u64,
    pub min_price: u64,
    pub max_price: u64,
    pub share: f64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SellerSummary {
    pub total_quantity: u64,
    pub attributed_quantity: u64,
    pub unattributed_quantity: u64,
    pub sellers: Vec<SellerShare>,
    pub shared_offers: Vec<SellerOffer>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OrderBookLevel {
    pub unit_price: u64,
    pub quantity: u64,
    pub cumulative_quantity: u64,
    pub cumulative_cost: u64,
    pub owners: BTreeSet<String>,
    pub has_unnamed_owners: bool,
}

impl SellerSnapshot {
    pub fn fingerprint(&self) -> String {
        sha256(serde_json::to_vec(self).unwrap())
    }

    pub fn order_book(&self) -> Vec<OrderBookLevel> {
        let mut levels = BTreeMap::new();
        for offer in &self.offers {
            let level = levels
                .entry(offer.unit_price)
                .or_insert_with(|| OrderBookLevel {
                    unit_price: offer.unit_price,
                    quantity: 0,
                    cumulative_quantity: 0,
                    cumulative_cost: 0,
                    owners: BTreeSet::new(),
                    has_unnamed_owners: false,
                });
            level.quantity += offer.quantity;
            level.owners.extend(offer.owners.iter().cloned());
            level.has_unnamed_owners |=
                offer.owners.is_empty() || offer.total_owners > offer.owners.len() as u64;
        }
        let (mut quantity, mut cost) = (0, 0);
        levels
            .into_values()
            .map(|mut level| {
                quantity += level.quantity;
                cost += level.unit_price * level.quantity;
                level.cumulative_quantity = quantity;
                level.cumulative_cost = cost;
                level
            })
            .collect()
    }

    pub fn summary(&self) -> SellerSummary {
        let mut totals: BTreeMap<&str, (u64, u64, u64)> = BTreeMap::new();
        let mut total_quantity = 0;
        let mut attributed_quantity = 0;
        let mut shared_offers = Vec::new();
        for offer in &self.offers {
            total_quantity += offer.quantity;
            // An aggregate with several owners gives no per-owner quantities.
            // Keep it separate rather than crediting every owner with its stock.
            if offer.owners.len() == 1 && offer.total_owners == 1 {
                let entry = totals.entry(&offer.owners[0]).or_insert((
                    0,
                    offer.unit_price,
                    offer.unit_price,
                ));
                entry.0 += offer.quantity;
                entry.1 = entry.1.min(offer.unit_price);
                entry.2 = entry.2.max(offer.unit_price);
                attributed_quantity += offer.quantity;
            } else {
                shared_offers.push(offer.clone());
            }
        }
        let mut sellers = totals
            .into_iter()
            .map(|(name, (quantity, min_price, max_price))| SellerShare {
                name: name.to_owned(),
                quantity,
                min_price,
                max_price,
                share: if total_quantity == 0 {
                    0.0
                } else {
                    quantity as f64 / total_quantity as f64
                },
            })
            .collect::<Vec<_>>();
        sellers.sort_by(|a, b| b.quantity.cmp(&a.quantity).then(a.name.cmp(&b.name)));
        SellerSummary {
            total_quantity,
            attributed_quantity,
            unattributed_quantity: total_quantity - attributed_quantity,
            sellers,
            shared_offers,
        }
    }
}
