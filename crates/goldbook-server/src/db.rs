use rusqlite::{Connection, OptionalExtension, functions::FunctionFlags};
use serde_json::Value;
use std::{path::Path, time::Duration};

const MIGRATIONS: [(&str, &str); 11] = [
    (
        "0001_init.sql",
        include_str!("../../../server/migrations/0001_init.sql"),
    ),
    (
        "0002_drop_prices_by_item.sql",
        include_str!("../../../server/migrations/0002_drop_prices_by_item.sql"),
    ),
    (
        "0003_accounts.sql",
        include_str!("../../../server/migrations/0003_accounts.sql"),
    ),
    (
        "0004_gold_hours.sql",
        include_str!("../../../server/migrations/0004_gold_hours.sql"),
    ),
    (
        "0005_scan_fingerprints.sql",
        include_str!("../../../server/migrations/0005_scan_fingerprints.sql"),
    ),
    (
        "0006_seller_snapshots.sql",
        include_str!("../../../server/migrations/0006_seller_snapshots.sql"),
    ),
    (
        "0007_trades.sql",
        include_str!("../../../server/migrations/0007_trades.sql"),
    ),
    (
        "0008_vendor_trades.sql",
        include_str!("../../../server/migrations/0008_vendor_trades.sql"),
    ),
    (
        "0009_linked_accounts.sql",
        include_str!("../../../server/migrations/0009_linked_accounts.sql"),
    ),
    (
        "0010_upload_tokens.sql",
        include_str!("../../../server/migrations/0010_upload_tokens.sql"),
    ),
    (
        "0011_battlenet_oauth.sql",
        include_str!("../../../server/migrations/0011_battlenet_oauth.sql"),
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
    for (name, sql) in MIGRATIONS {
        let applied: Option<String> = db
            .query_row("SELECT name FROM migrations WHERE name=?1", [name], |r| {
                r.get(0)
            })
            .optional()?;
        if applied.is_some() {
            continue;
        }
        let tx = db.transaction()?;
        tx.execute_batch(sql)?;
        tx.execute("INSERT INTO migrations VALUES (?1, unixepoch())", [name])?;
        tx.commit()?;
    }
    Ok(())
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
