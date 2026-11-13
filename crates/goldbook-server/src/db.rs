use crate::house::House;
use goldbook_core::ScanUpload;
use rusqlite::{
    Connection, OptionalExtension, Transaction, TransactionBehavior, functions::FunctionFlags,
    params,
};
use serde_json::Value;
use std::{path::Path, time::Duration};

/// One migration: a file under server/migrations, or a change to the data
/// that SQL alone cannot express. Each runs once, in its own transaction.
enum Step {
    Sql(&'static str),
    Code(fn(&Transaction) -> rusqlite::Result<()>),
}
impl Step {
    fn apply(&self, tx: &Transaction) -> rusqlite::Result<()> {
        match self {
            Step::Sql(sql) => tx.execute_batch(sql),
            Step::Code(run) => run(tx),
        }
    }
}

const MIGRATIONS: [(&str, Step); 19] = [
    (
        "0001_init.sql",
        Step::Sql(include_str!("../../../server/migrations/0001_init.sql")),
    ),
    (
        "0002_drop_prices_by_item.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0002_drop_prices_by_item.sql"
        )),
    ),
    (
        "0003_accounts.sql",
        Step::Sql(include_str!("../../../server/migrations/0003_accounts.sql")),
    ),
    (
        "0004_gold_hours.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0004_gold_hours.sql"
        )),
    ),
    (
        "0005_scan_fingerprints.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0005_scan_fingerprints.sql"
        )),
    ),
    (
        "0006_seller_snapshots.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0006_seller_snapshots.sql"
        )),
    ),
    (
        "0007_trades.sql",
        Step::Sql(include_str!("../../../server/migrations/0007_trades.sql")),
    ),
    (
        "0008_vendor_trades.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0008_vendor_trades.sql"
        )),
    ),
    (
        "0009_linked_accounts.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0009_linked_accounts.sql"
        )),
    ),
    (
        "0010_upload_tokens.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0010_upload_tokens.sql"
        )),
    ),
    (
        "0011_battlenet_oauth.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0011_battlenet_oauth.sql"
        )),
    ),
    (
        "0012_accounting.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0012_accounting.sql"
        )),
    ),
    (
        "0013_account_identities.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0013_account_identities.sql"
        )),
    ),
    (
        "0014_battlenet_web.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0014_battlenet_web.sql"
        )),
    ),
    (
        "0015_latest_prices.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0015_latest_prices.sql"
        )),
    ),
    (
        "0016_auction_houses.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0016_auction_houses.sql"
        )),
    ),
    (
        "0017_item_sources.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0017_item_sources.sql"
        )),
    ),
    (
        "0018_hidden_trades.sql",
        Step::Sql(include_str!(
            "../../../server/migrations/0018_hidden_trades.sql"
        )),
    ),
    (
        "0019_balance_correction",
        Step::Code(crate::balance::correct),
    ),
];

pub fn connect(path: &Path) -> anyhow::Result<Connection> {
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    let db = Connection::open(path)?;
    db.busy_timeout(Duration::from_secs(30))?;
    db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;
    db.create_scalar_function("scan_fingerprint", 1, FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC, |ctx| {
        let encoded: String = ctx.get(0)?;
        let identity: Value = serde_json::from_str(&encoded).map_err(|e| rusqlite::Error::UserFunctionError(Box::new(e)))?;
        let scan = serde_json::json!({"realm": identity[0], "faction": identity[1], "region": identity[2],
            "scannedAt": identity[3], "mode": identity[4], "scanner": identity[5], "build": identity[6],
            "rows": identity[7], "items": {}});
        serde_json::from_value::<goldbook_core::ScanUpload>(scan).map(|s| s.fingerprint())
            .map_err(|e| rusqlite::Error::UserFunctionError(Box::new(e)))
    })?;
    Ok(db)
}

pub fn migrate(db: &mut Connection) -> anyhow::Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)")?;
    for (name, step) in MIGRATIONS {
        let applied: Option<String> = db
            .query_row("SELECT name FROM migrations WHERE name=?1", [name], |r| {
                r.get(0)
            })
            .optional()?;
        if applied.is_some() {
            continue;
        }
        let tx = db.transaction()?;
        step.apply(&tx)?;
        tx.execute("INSERT INTO migrations VALUES (?1, unixepoch())", [name])?;
        tx.commit()?;
    }
    Ok(())
}

/// Stores a scan, its item names and its prices, and makes it the newest
/// price of each item it holds unless a newer scan already is. False when the
/// same scan was stored before, which stores only its names.
pub(crate) fn store_scan(db: &mut Connection, scan: &ScanUpload) -> rusqlite::Result<bool> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let house = House::of(&scan.realm);
    // The fingerprint keeps the realm, so a retry still deduplicates and two
    // shards of one house never collide.
    let inserted = tx.execute("INSERT INTO scans (realm,faction,region,scanned_at,mode,scanner,build,item_count,uploaded_at,fingerprint,house) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,unixepoch(),?9,?10) ON CONFLICT(fingerprint) DO NOTHING",params![scan.realm,scan.faction,scan.region,scan.scanned_at as i64,scan.mode,scan.scanner,scan.build,scan.rows.len() as i64,scan.fingerprint(),house])?;
    let id = tx.last_insert_rowid();
    {
        // The addon keeps the names it imports from ServerData.lua and uploads
        // them with its scans, so a name that matches the stored one keeps
        // the stored source.
        let mut items = tx.prepare("INSERT INTO items (item_key,name,quality,source) VALUES (?1,?2,?3,'player') ON CONFLICT(item_key) DO UPDATE SET name=excluded.name,quality=excluded.quality,source='player' WHERE items.name IS NOT excluded.name OR items.quality IS NOT excluded.quality")?;
        for (key, (name, quality)) in &scan.items {
            items.execute(params![key, name, *quality as i64])?;
        }
        if inserted == 1 {
            let mut prices = tx.prepare("INSERT INTO prices (scan_id,item_key,min_buyout,market_value,quantity,num_auctions) VALUES (?1,?2,?3,?4,?5,?6)")?;
            for (key, min, market, quantity, auctions) in &scan.rows {
                prices.execute(params![
                    id,
                    key,
                    *min as i64,
                    *market as i64,
                    *quantity as i64,
                    *auctions as i64
                ])?;
            }
            // A scan uploaded late does not replace a newer price.
            tx.execute(
                "INSERT INTO latest_prices (house,faction,item_key,scan_id) SELECT ?2,?3,item_key,scan_id FROM prices WHERE scan_id=?1 ON CONFLICT(house,faction,item_key) DO UPDATE SET scan_id=excluded.scan_id WHERE (SELECT scanned_at,id FROM scans WHERE id=excluded.scan_id) > (SELECT scanned_at,id FROM scans WHERE id=latest_prices.scan_id)",
                params![id, house, scan.faction],
            )?;
        }
    }
    tx.commit()?;
    Ok(inserted == 1)
}

pub fn query(
    db: &Connection,
    sql: &str,
    params: &[&dyn rusqlite::ToSql],
) -> rusqlite::Result<Vec<Value>> {
    let mut stmt = db.prepare(sql)?;
    let names: Vec<String> = stmt.column_names().iter().map(|s| (*s).into()).collect();
    stmt.query_map(params, |row| {
        let mut out = serde_json::Map::new();
        for (i, name) in names.iter().enumerate() {
            let value = match row.get_ref(i)? {
                rusqlite::types::ValueRef::Null => Value::Null,
                rusqlite::types::ValueRef::Integer(n) => Value::from(n),
                rusqlite::types::ValueRef::Real(n) => Value::from(n),
                rusqlite::types::ValueRef::Text(s) => {
                    Value::String(String::from_utf8_lossy(s).into())
                }
                rusqlite::types::ValueRef::Blob(_) => {
                    return Err(rusqlite::Error::InvalidColumnType(
                        i,
                        name.clone(),
                        rusqlite::types::Type::Blob,
                    ));
                }
            };
            out.insert(name.clone(), value);
        }
        Ok(Value::Object(out))
    })?
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_stored_before_item_sources_stay_players_names() {
        let mut db = connect(Path::new(":memory:")).unwrap();
        db.execute_batch(
            "CREATE TABLE migrations (name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)",
        )
        .unwrap();
        let tx = db.transaction().unwrap();
        for (name, step) in &MIGRATIONS[..16] {
            step.apply(&tx).unwrap();
            tx.execute("INSERT INTO migrations VALUES (?1, 0)", [name])
                .unwrap();
        }
        tx.commit().unwrap();
        db.execute(
            "INSERT INTO items (item_key,name,quality) VALUES (?1,?2,?3)",
            params!["2589", "Linen Cloth", 1],
        )
        .unwrap();

        migrate(&mut db).unwrap();
        assert_eq!(
            query(&db, "SELECT * FROM items", &[]).unwrap(),
            [
                serde_json::json!({"item_key":"2589","name":"Linen Cloth","quality":1,"source":"player"})
            ]
        );
    }
}
