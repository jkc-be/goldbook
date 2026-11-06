//! The auction house a realm's scans belong to.
//!
//! Every read endpoint takes `realm` and `faction` from the client as before
//! and answers from the house that realm maps to. A house name is an opaque
//! string that `HouseRules::of` owns: today it derives from a WoW Forever
//! shard name, later a new rule can name a Blizzard API house instead.
//!
//! `of` is a fixed point, `of(of(r)) == of(r)`, so a house name answers for
//! itself and the website can ask for what `/api/realms` listed. The default
//! is `HouseRules::Forever`. Under `HouseRules::Off`, which
//! `SHARDING_AUCTION_HOUSES=off` selects, every realm is its own house, so
//! nothing stored or served differs from before this module existed. Faction
//! is never folded into the house: the key everywhere is `(house, faction)`.

use anyhow::{Result, bail};
use rusqlite::{Connection, ToSql, TransactionBehavior, params, types::ToSqlOutput};

/// The rule set `SHARDING_AUCTION_HOUSES` selects at startup.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum HouseRules {
    /// Every realm is its own house.
    Off,
    /// WoW Forever shards of one cluster and ruleset share a house:
    /// `CAMWOW<cluster>Realm<shard><kind>` maps to `CAMWOW<cluster>Realm<kind>`.
    /// Everything else is its own house.
    #[default]
    Forever,
}

impl HouseRules {
    /// Unset or blank is the default, `Forever`. Anything but `forever` or
    /// `off` refuses to start, so a typo in the deployment is not a silent
    /// default.
    pub fn from_env(value: Option<&str>) -> Result<Self> {
        match value.map(str::trim).unwrap_or("") {
            "" | "forever" => Ok(Self::Forever),
            "off" => Ok(Self::Off),
            other => bail!("SHARDING_AUCTION_HOUSES must be unset, forever or off, not {other:?}"),
        }
    }

    pub fn of(self, realm: &str) -> House {
        House(match self {
            Self::Off => realm.to_owned(),
            Self::Forever => forever_shard(realm).unwrap_or_else(|| realm.to_owned()),
        })
    }
}

/// A house name, so that a handler cannot bind a raw realm where the house
/// belongs. Not a wire type: the API keeps `realm` in queries and bodies.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct House(String);

impl House {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl ToSql for House {
    fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
        self.0.to_sql()
    }
}

/// `CAMWOWEU4Realm8PvP` → `CAMWOWEU4RealmPvP`. None for any other shape,
/// including a house name, which has no digits after `Realm`.
///
/// The pattern is inferred from two shard names and kept narrow on purpose:
/// the cluster (`EU4`) and the kind (`PvP`) stay in the house, so a wrong
/// guess under-pools and hides prices instead of showing another house's.
fn forever_shard(realm: &str) -> Option<String> {
    let rest = realm.strip_prefix("CAMWOW")?;
    let (cluster, after) = rest.split_once("Realm")?;
    let letters = cluster.trim_end_matches(|c: char| c.is_ascii_digit());
    if letters.is_empty()
        || letters.len() == cluster.len()
        || !letters.bytes().all(|b| b.is_ascii_alphabetic())
    {
        return None;
    }
    let kind = after.trim_start_matches(|c: char| c.is_ascii_digit());
    if kind.len() == after.len() || !kind.bytes().all(|b| b.is_ascii_alphabetic()) {
        return None;
    }
    Some(format!("CAMWOW{cluster}Realm{kind}"))
}

/// The rows `reconcile` moved to another house.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Reconciled {
    pub scans: usize,
    pub snapshots: usize,
}

/// Converges the stored `house` of every scan and seller snapshot, and the
/// `latest_prices` keyed by it, to `rules`. Runs after `db::migrate` at every
/// start, so that changing the rule needs no migration and toggling it back
/// converges the other way. Idempotent: a second run moves nothing and
/// rebuilds nothing. One transaction, so a crash midway leaves the old state.
pub fn reconcile(db: &mut Connection, rules: HouseRules) -> Result<Reconciled> {
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
            let wanted = rules.of(&realm);
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
    fn forever_shards_of_one_cluster_and_kind_share_a_house() {
        for (realm, house) in [
            ("CAMWOWEU4Realm8PvP", "CAMWOWEU4RealmPvP"),
            ("CAMWOWEU4Realm6PvP", "CAMWOWEU4RealmPvP"),
            ("CAMWOWEU4Realm12PvP", "CAMWOWEU4RealmPvP"),
            ("CAMWOWEU4Realm3", "CAMWOWEU4Realm"),
            ("CAMWOWEU4Realm2RP", "CAMWOWEU4RealmRP"),
            ("CAMWOWEU1Realm8PvP", "CAMWOWEU1RealmPvP"),
            ("CAMWOWUS4Realm8PvP", "CAMWOWUS4RealmPvP"),
            ("CAMWOWEU4Realm8PvE", "CAMWOWEU4RealmPvE"),
        ] {
            assert_eq!(HouseRules::Forever.of(realm).as_str(), house, "{realm}");
            assert_eq!(HouseRules::Off.of(realm).as_str(), realm, "{realm}");
        }
    }

    #[test]
    fn other_names_are_their_own_house_under_either_rule() {
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
            assert_eq!(HouseRules::Forever.of(realm).as_str(), realm, "{realm}");
            assert_eq!(HouseRules::Off.of(realm).as_str(), realm, "{realm}");
        }
    }

    #[test]
    fn a_house_name_maps_to_itself() {
        for realm in ["CAMWOWEU4Realm8PvP", "CAMWOWEU4Realm3", "Faramon"] {
            let house = HouseRules::Forever.of(realm);
            assert_eq!(HouseRules::Forever.of(house.as_str()), house);
        }
    }

    #[test]
    fn the_environment_selects_the_rules() {
        assert_eq!(HouseRules::from_env(None).unwrap(), HouseRules::Forever);
        assert_eq!(
            HouseRules::from_env(Some(" ")).unwrap(),
            HouseRules::Forever
        );
        assert_eq!(
            HouseRules::from_env(Some("forever")).unwrap(),
            HouseRules::Forever
        );
        assert_eq!(HouseRules::from_env(Some("off")).unwrap(), HouseRules::Off);
        assert_eq!(
            HouseRules::from_env(Some("Forever"))
                .unwrap_err()
                .to_string(),
            "SHARDING_AUCTION_HOUSES must be unset, forever or off, not \"Forever\""
        );
    }
}
