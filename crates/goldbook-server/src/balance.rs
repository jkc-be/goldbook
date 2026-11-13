//! The one-time repair of the ledger that migration 0019_balance_correction
//! runs.
//!
//! Addons before 0.5.4 on WoW Forever booked the merchant's whole buyback list
//! again as new vendor sales each time a merchant opened, all in the second
//! the visit began. The server keeps every entry it was sent, so those sales
//! inflated revenue. `correct` hides the re-bookings, then books one entry per
//! character that brings its revenue less expenses to the gold it holds.

use rusqlite::{Transaction, params, types::Type};
use std::{
    cmp::Ordering,
    collections::{BTreeMap, HashMap, VecDeque},
};

/// Sales this many seconds apart or more belong to different merchant visits.
const VISIT_GAP: i64 = 30;
const RECENT_SALES: usize = 48;
const LEAST_REPEATS: usize = 3;
/// The sides the website counts as revenue, in web/app.js.
const REVENUE: &str = "'sell','vendor','tradeSell','tradeIn','mailIn','quest','loot','otherIn'";

/// A vendor sale of one character, as one account ID uploaded it. The fields
/// up to `copy` are its primary key in the table's order, so sorting sales
/// sorts them as the table does.
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Sale {
    at: i64,
    item: String,
    count: i64,
    price: i64,
    fee: i64,
    copy: i64,
    item_key: Option<String>,
}
impl Sale {
    fn repeats(&self, earlier: &Sale) -> bool {
        self.item == earlier.item
            && self.item_key == earlier.item_key
            && self.count == earlier.count
            && self.price == earlier.price
    }
    /// The sales of one second that an upload tells apart only by `copy`.
    fn lot(&self) -> (&str, i64, i64, i64) {
        (&self.item, self.count, self.price, self.fee)
    }
}

/// The sales that re-book earlier ones. A re-booking opens a merchant visit:
/// three or more sales in its first second that each repeat a recent sale of
/// an earlier visit. Equal sales of that second are hidden together, and only
/// when every one of them repeats.
fn rebooked(sales: &[Sale]) -> Vec<&Sale> {
    let mut sales: Vec<&Sale> = sales.iter().collect();
    sales.sort();
    let mut recent: VecDeque<&Sale> = VecDeque::with_capacity(RECENT_SALES);
    let mut hidden = Vec::new();
    for visit in sales.chunk_by(|a, b| b.at - a.at < VISIT_GAP) {
        let first = &visit[..visit.partition_point(|sale| sale.at == visit[0].at)];
        let repeats = |sale: &&Sale| recent.iter().any(|earlier| sale.repeats(earlier));
        let rebooking = first.iter().filter(|sale| repeats(sale)).count() >= LEAST_REPEATS;
        let hide: Vec<&Sale> = if rebooking {
            first
                .chunk_by(|a, b| a.lot() == b.lot())
                .filter(|lot| lot.iter().all(repeats))
                .flatten()
                .copied()
                .collect()
        } else {
            Vec::new()
        };
        for &sale in visit.iter().filter(|sale| !hide.contains(sale)) {
            if recent.len() == RECENT_SALES {
                recent.pop_front();
            }
            recent.push_back(sale);
        }
        hidden.extend(hide);
    }
    hidden
}

pub(crate) fn correct(tx: &Transaction) -> rusqlite::Result<()> {
    hide_rebookings(tx)?;
    book_corrections(tx)
}

fn hide_rebookings(tx: &Transaction) -> rusqlite::Result<()> {
    let mut ledgers: BTreeMap<(String, String, String), Vec<Sale>> = BTreeMap::new();
    let mut select = tx.prepare(
        "SELECT account_id,name,realm,at,item,count,price,fee,copy,item_key FROM trades WHERE side='vendor'",
    )?;
    let mut rows = select.query([])?;
    while let Some(row) = rows.next()? {
        ledgers
            .entry((row.get(0)?, row.get(1)?, row.get(2)?))
            .or_default()
            .push(Sale {
                at: row.get(3)?,
                item: row.get(4)?,
                count: row.get(5)?,
                price: row.get(6)?,
                fee: row.get(7)?,
                copy: row.get(8)?,
                item_key: row.get(9)?,
            });
    }
    let mut hide = tx.prepare(
        "UPDATE trades SET hidden=1 WHERE account_id=?1 AND name=?2 AND realm=?3 AND at=?4 AND side='vendor' AND item=?5 AND count=?6 AND price=?7 AND fee=?8 AND copy=?9",
    )?;
    for ((account, name, realm), sales) in &ledgers {
        for sale in rebooked(sales) {
            hide.execute(params![
                account, name, realm, sale.at, sale.item, sale.count, sale.price, sale.fee,
                sale.copy
            ])?;
        }
    }
    Ok(())
}

/// A character as the website merges it from every ID that uploaded it.
#[derive(Default)]
struct Character {
    /// The ID of its newest upload, which the correction is booked under.
    account_id: String,
    /// Copper by hour, the newer upload winning an hour both have.
    gold: BTreeMap<i64, i64>,
}

fn book_corrections(tx: &Transaction) -> rusqlite::Result<()> {
    let mut characters: BTreeMap<(String, String), Character> = BTreeMap::new();
    let mut select = tx.prepare(
        "SELECT name,realm,account_id,gold FROM characters ORDER BY updated_at NULLS FIRST,account_id",
    )?;
    let mut rows = select.query([])?;
    while let Some(row) = rows.next()? {
        let gold: String = row.get(3)?;
        let gold: Vec<(i64, i64)> = serde_json::from_str(&gold)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(3, Type::Text, Box::new(e)))?;
        let character = characters.entry((row.get(0)?, row.get(1)?)).or_default();
        character.account_id = row.get(2)?;
        character.gold.extend(gold);
    }
    // A trade that more than one ID uploaded counts once, as in /api/trades.
    let net: HashMap<(String, String), i64> = tx
        .prepare(&format!(
            "SELECT name,realm,SUM(CASE WHEN side IN ({REVENUE}) THEN price-fee ELSE -price END) FROM (SELECT DISTINCT name,realm,at,side,item,count,price,fee,copy FROM trades WHERE hidden=0) GROUP BY name,realm"
        ))?
        .query_map([], |row| Ok(((row.get(0)?, row.get(1)?), row.get(2)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let mut book = tx.prepare(
        "INSERT INTO trades (account_id,name,realm,at,side,item,count,price,fee,copy) VALUES (?1,?2,?3,?4,?5,'Balance correction',1,?6,0,0) ON CONFLICT DO NOTHING",
    )?;
    for (key, character) in &characters {
        let Some((&hour, &gold)) = character.gold.last_key_value() else {
            continue;
        };
        let difference = gold - net.get(key).copied().unwrap_or(0);
        let (side, price) = match difference.cmp(&0) {
            Ordering::Greater => ("otherIn", difference),
            Ordering::Less => ("otherOut", -difference),
            Ordering::Equal => continue,
        };
        // The newest gold is the balance at the end of its hour.
        book.execute(params![
            character.account_id,
            key.0,
            key.1,
            hour + 3599,
            side,
            price
        ])?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sale(at: i64, item: &str, price: i64) -> Sale {
        Sale {
            at,
            item: item.into(),
            count: 1,
            price,
            fee: 0,
            copy: 0,
            item_key: None,
        }
    }
    fn hidden(sales: &[Sale]) -> Vec<(i64, &str, i64)> {
        rebooked(sales)
            .into_iter()
            .map(|sale| (sale.at, sale.item.as_str(), sale.copy))
            .collect()
    }

    #[test]
    fn a_sale_repeats_only_a_sale_of_the_same_item_key() {
        let star = |at, key: &str| Sale {
            item_key: Some(key.into()),
            ..sale(at, "Jagged Star of the Eagle", 3100)
        };
        let visits = |key| {
            [
                star(0, "15301:1019"),
                sale(0, "Broken Fang", 85),
                sale(0, "Ruined Pelt", 55),
                sale(600, "Broken Fang", 85),
                sale(600, "Ruined Pelt", 55),
                star(600, key),
            ]
        };
        assert_eq!(
            hidden(&visits("15301:1020")),
            [],
            "two repeats are no re-booking"
        );
        assert_eq!(
            hidden(&visits("15301:1019")),
            [
                (600, "Broken Fang", 0),
                (600, "Jagged Star of the Eagle", 0),
                (600, "Ruined Pelt", 0)
            ]
        );
    }

    #[test]
    fn equal_sales_of_one_second_are_hidden_together_or_not_at_all() {
        let visits = |key: Option<&str>| {
            [
                sale(0, "Broken Fang", 85),
                sale(0, "Light Leather", 40),
                sale(0, "Ruined Pelt", 55),
                sale(600, "Broken Fang", 85),
                Sale {
                    copy: 1,
                    item_key: key.map(Into::into),
                    ..sale(600, "Broken Fang", 85)
                },
                sale(600, "Light Leather", 40),
                sale(600, "Ruined Pelt", 55),
            ]
        };
        assert_eq!(
            hidden(&visits(None)),
            [
                (600, "Broken Fang", 0),
                (600, "Broken Fang", 1),
                (600, "Light Leather", 0),
                (600, "Ruined Pelt", 0)
            ],
            "both fangs repeat the one fang sold before"
        );
        assert_eq!(
            hidden(&visits(Some("4582"))),
            [(600, "Light Leather", 0), (600, "Ruined Pelt", 0)],
            "the second fang names an item key the first sale lacked"
        );
    }

    #[test]
    fn a_sale_repeats_only_the_last_48_sales_kept() {
        let visits = |between: usize| {
            let names = ["Broken Fang", "Light Leather", "Ruined Pelt", "Wool Cloth"];
            let mut sales: Vec<Sale> = names.iter().map(|name| sale(0, name, 10)).collect();
            sales.extend((0..between).map(|n| sale(100, &format!("Item {n:02}"), 1)));
            sales.extend(names.iter().map(|name| sale(600, name, 10)));
            sales
        };
        assert_eq!(
            hidden(&visits(44)),
            [
                (600, "Broken Fang", 0),
                (600, "Light Leather", 0),
                (600, "Ruined Pelt", 0),
                (600, "Wool Cloth", 0)
            ]
        );
        assert_eq!(
            hidden(&visits(45)),
            [
                (600, "Light Leather", 0),
                (600, "Ruined Pelt", 0),
                (600, "Wool Cloth", 0)
            ],
            "the fang, first by key, fell out of the 48"
        );
    }
}
