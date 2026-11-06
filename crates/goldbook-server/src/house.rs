//! The auction house a realm's scans belong to.
//!
//! A house is the Blizzard auction house that a realm's scans come from. WoW
//! Forever shards of one region and ruleset share one, so their scans pool
//! there. Every other realm is its own house for now. Faction is never folded
//! into the house: the key everywhere is `(house, faction)`.
//!
//! Every read endpoint takes `realm` and `faction` from the client as before
//! and answers from the house that realm belongs to. A house name is the
//! server's own string, which `House::of` owns: today it derives from a WoW
//! Forever shard name, later a rule can name a Battle.net API house instead.
//! `House::of` maps a house name to itself, so a house name answers for itself
//! and the website can ask for what `/api/realms` listed. `reconcile` runs at
//! every start, so a rule change in code needs no migration.

use anyhow::Result;
use rusqlite::{Connection, ToSql, TransactionBehavior, params, types::ToSqlOutput};

/// A house name, so that a handler cannot bind a raw realm where the house
/// belongs. Not a wire type: the API keeps `realm` in queries and bodies.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct House(String);

impl House {
    /// A WoW Forever shard such as `CAMWOWEU4Realm8PvP` belongs to its region
    /// and ruleset, `EU PvP`; every other realm is its own house.
    pub fn of(realm: &str) -> House {
        House(forever_shard(realm).unwrap_or_else(|| realm.to_owned()))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl ToSql for House {
    fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
        self.0.to_sql()
    }
}

/// `CAMWOWEU4Realm8PvP` → `EU PvP`, `CAMWOWEU4Realm3` → `EU Normal`. None for
/// any other shape, including a house name.
///
/// Blizzard runs one auction house per region, ruleset and faction (issue
/// #67), so the cluster digit and the shard number are dropped. Any other
/// shape stays its own house, so a name this does not know hides prices
/// instead of showing another house's.
fn forever_shard(realm: &str) -> Option<String> {
    let rest = realm.strip_prefix("CAMWOW")?;
    let (cluster, after) = rest.split_once("Realm")?;
    let region = cluster.trim_end_matches(|c: char| c.is_ascii_digit());
    if region.is_empty()
        || region.len() == cluster.len()
        || !region.bytes().all(|b| b.is_ascii_alphabetic())
    {
        return None;
    }
    let kind = after.trim_start_matches(|c: char| c.is_ascii_digit());
    if kind.len() == after.len() || !kind.bytes().all(|b| b.is_ascii_alphabetic()) {
        return None;
    }
    let ruleset = if kind.is_empty() { "Normal" } else { kind };
    Some(format!("{region} {ruleset}"))
}

/// The rows `reconcile` moved to another house.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Reconciled {
    pub scans: usize,
    pub snapshots: usize,
}

/// Converges the stored `house` of every scan and seller snapshot, and the
/// `latest_prices` keyed by it, to the house its realm belongs to. Runs after
/// `db::migrate` at every start, so a rule change in code needs no migration.
/// Idempotent: a second run moves nothing and rebuilds nothing. One
/// transaction, so a crash midway leaves the old state.
pub fn reconcile(db: &mut Connection) -> Result<Reconciled> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut moved = Reconciled::default();
    for (table, count) in [
        ("scans", &mut moved.scans),
        ("seller_snapshots", &mut moved.snapshots),
    ] {
        let stored: Vec<(String, String)> = tx
            .prepare(&format!(
                "SELECT realm, house FROM {table} GROUP BY realm, house"
            ))?
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        for (realm, house) in stored {
            let wanted = House::of(&realm);
            if wanted.as_str() != house {
                *count += tx.execute(
                    &format!("UPDATE {table} SET house=?1 WHERE realm=?2 AND house=?3"),
                    params![wanted, realm, house],
                )?;
            }
        }
    }
    if moved.scans > 0 {
        tx.execute_batch(
            "DELETE FROM latest_prices;
             INSERT INTO latest_prices (house, faction, item_key, scan_id)
             SELECT house, faction, item_key, scan_id FROM (
               SELECT s.house, s.faction, p.item_key, p.scan_id,
                 ROW_NUMBER() OVER (PARTITION BY s.house, s.faction, p.item_key ORDER BY s.scanned_at DESC, s.id DESC) AS newest
               FROM prices p JOIN scans s ON s.id = p.scan_id
             ) WHERE newest = 1",
        )?;
    }
    tx.commit()?;
    Ok(moved)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forever_shards_of_one_region_and_ruleset_share_a_house() {
        for (realm, house) in [
            ("CAMWOWEU4Realm8PvP", "EU PvP"),
            ("CAMWOWEU4Realm6PvP", "EU PvP"),
            ("CAMWOWEU4Realm12PvP", "EU PvP"),
            ("CAMWOWEU1Realm8PvP", "EU PvP"),
            ("CAMWOWEU12Realm8PvP", "EU PvP"),
            ("CAMWOWUS4Realm8PvP", "US PvP"),
            ("CAMWOWEU4Realm2RP", "EU RP"),
            ("CAMWOWEU4Realm8PvE", "EU PvE"),
            ("CAMWOWEU4Realm3", "EU Normal"),
            ("CAMWOWUS1Realm3", "US Normal"),
        ] {
            assert_eq!(House::of(realm).as_str(), house, "{realm}");
        }
    }

    #[test]
    fn other_names_are_their_own_house() {
        for realm in [
            "Faramon",
            "Pyrewood Village",
            "Azjol-Nerub",
            "ClassicBetaPvP2",
            "CAMWOWEU4RealmPvP",
            "CAMWOWEU4Realm",
            "CAMWOWRealm8PvP",
            "CAMWOW4Realm8PvP",
            "CAMWOWEURealm8PvP",
            "CAMWOWEU4Realm8PvP2",
            "CAMWOWEU4Realm8Pv-P",
            "camwowEU4Realm8PvP",
            "",
        ] {
            assert_eq!(House::of(realm).as_str(), realm, "{realm}");
        }
    }

    #[test]
    fn a_house_name_maps_to_itself() {
        for (realm, house) in [
            ("CAMWOWEU4Realm8PvP", "EU PvP"),
            ("CAMWOWUS4Realm3", "US Normal"),
            ("Faramon", "Faramon"),
        ] {
            assert_eq!(House::of(realm).as_str(), house, "{realm}");
            assert_eq!(House::of(house).as_str(), house, "{house}");
        }
    }
}
