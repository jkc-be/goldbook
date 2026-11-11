use crate::{App, Error, Input, Reply, Result, db, hash, house::House, now};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};

/// A stored trade's key besides its account, name and realm: at, side, item,
/// count, price, fee and copy.
type TradeKey = (i64, String, String, i64, i64, i64, i64);

pub(super) fn register_installation(
    input: &Input,
    app: &App,
    db: &mut Connection,
) -> Result<Reply> {
    // Every upload token belongs to a Battle.net player.
    if app.config.battlenet.is_none() {
        return Err(Error::new(403, "installation registration is disabled"));
    }
    let wait = app.registrations.lock().unwrap().begin(
        None,
        Some(input.client.as_deref().unwrap_or("unknown")),
        now(),
    );
    if wait > 0 {
        return Err(Error::new(429, "too many registrations, try again later"));
    }
    let body = input.json()?;
    let fingerprint = body["fingerprint"].as_str().unwrap_or_default();
    if body.as_object().is_none_or(|object| object.len() != 2)
        || body["fingerprintVersion"].as_u64() != Some(1)
        || fingerprint.len() != 64
        || !fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(Error::new(
            400,
            "provide a version 1 account fingerprint as 64 lowercase hexadecimal characters",
        ));
    }
    let token = format!("gb_{}", URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>()));
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let identity = crate::oauth::enrollment_identity(input, &tx)?;
    tx.execute(
        "INSERT INTO upload_identities (fingerprint) VALUES (?1) ON CONFLICT(fingerprint) DO NOTHING",
        [fingerprint],
    )?;
    let blocked: bool = tx.query_row(
        "SELECT blocked_at IS NOT NULL FROM upload_identities WHERE fingerprint=?1",
        [fingerprint],
        |row| row.get(0),
    )?;
    if blocked {
        return Err(Error::new(403, "this account is blocked"));
    }
    let existing: Option<String> = tx.query_row(
        "SELECT battlenet_identity FROM upload_identities WHERE fingerprint=?1",
        [fingerprint],
        |row| row.get(0),
    )?;
    if existing
        .as_deref()
        .is_some_and(|previous| previous != identity)
    {
        return Err(Error::new(
            409,
            "this account is linked to another Battle.net player",
        ));
    }
    // Tokens registered before Battle.net sign-in no longer upload.
    if existing.is_none() {
        tx.execute(
            "UPDATE upload_tokens SET revoked_at=?1 WHERE fingerprint=?2",
            params![now(), fingerprint],
        )?;
    }
    tx.execute(
        "UPDATE upload_identities SET battlenet_identity=?1 WHERE fingerprint=?2",
        params![identity, fingerprint],
    )?;
    tx.execute(
        "INSERT INTO upload_tokens (token_hash,fingerprint,created_at) VALUES (?1,?2,?3)",
        params![hash(&token), fingerprint, now()],
    )?;
    tx.commit()?;
    let mut reply = Reply::json(json!({"token":token}));
    reply.headers.push(("cache-control", "no-store".into()));
    Ok(reply)
}

pub(super) fn upload_scan(input: &Input, polling: bool, db: &mut Connection) -> Result<Reply> {
    let scan = input.upload(goldbook_core::parse_scan_upload)?;
    // The poller finds its newest snapshot by this scanner, so an upload
    // dated later under it would hold the poller back until then.
    if polling && scan.scanner == crate::auctions::SCANNER {
        return Err(Error::new(
            400,
            format!("scanner {} is reserved", crate::auctions::SCANNER),
        ));
    }
    let stored = db::store_scan(db, &scan)?;
    Ok(Reply::json(
        json!({"stored":stored,"items":scan.rows.len()}),
    ))
}
pub(super) fn upload_sellers(input: &Input, db: &mut Connection) -> Result<Reply> {
    let snapshot = input.upload(goldbook_core::parse_seller_snapshot)?;
    let inserted = db.execute(
        "INSERT INTO seller_snapshots (fingerprint,realm,faction,item_key,scanned_at,payload,house) VALUES (?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(fingerprint) DO NOTHING",
        params![snapshot.fingerprint(), snapshot.realm, snapshot.faction, snapshot.item_key,
            snapshot.scanned_at as i64, serde_json::to_string(&snapshot).map_err(|e| Error::new(400, e.to_string()))?,
            House::of(&snapshot.realm)],
    )?;
    Ok(Reply::json(json!({"stored": inserted == 1})))
}

pub(super) fn upload_seller_batch(input: &Input, db: &mut Connection) -> Result<Reply> {
    let snapshots = input.upload(|value| {
        let values = value.as_array().ok_or("seller batch must be an array")?;
        if values.is_empty() || values.len() > goldbook_core::MAX_SELLER_BATCH {
            return Err("seller batch must contain 1 to 100 snapshots".into());
        }
        values
            .iter()
            .map(goldbook_core::parse_seller_snapshot)
            .collect::<std::result::Result<Vec<_>, _>>()
    })?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut inserted = 0;
    {
        let mut statement = tx.prepare_cached(
            "INSERT INTO seller_snapshots (fingerprint,realm,faction,item_key,scanned_at,payload,house) VALUES (?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(fingerprint) DO NOTHING",
        )?;
        for snapshot in &snapshots {
            inserted += statement.execute(params![
                snapshot.fingerprint(),
                snapshot.realm,
                snapshot.faction,
                snapshot.item_key,
                snapshot.scanned_at as i64,
                serde_json::to_string(snapshot).map_err(|e| Error::new(400, e.to_string()))?,
                House::of(&snapshot.realm)
            ])?;
        }
    }
    tx.commit()?;
    Ok(Reply::json(
        json!({"stored": inserted, "received": snapshots.len()}),
    ))
}
pub(super) fn upload_account(input: &Input, db: &mut Connection) -> Result<Reply> {
    let account = input.upload(goldbook_core::parse_account_upload)?;
    let mut characters = BTreeMap::new();
    for c in &account.characters {
        characters.insert((&c.name, &c.realm), c);
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let stored: Option<String> = tx
        .query_row(
            "SELECT key_hash FROM accounts WHERE id=?1",
            [&account.id],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(stored) = stored {
        if stored != account.key_hash && Some(&stored) != account.previous_key_hash.as_ref() {
            return Err(Error::new(409, "this ID belongs to another key"));
        }
        if stored != account.key_hash {
            tx.execute("DELETE FROM sessions WHERE account_id=?1", [&account.id])?;
            // A new key also shuts out the other players who uploaded the ID.
            tx.execute(
                "DELETE FROM account_identities WHERE account_id=?1",
                [&account.id],
            )?;
        }
    }
    tx.execute("INSERT INTO accounts (id,key_hash,updated_at) VALUES (?1,?2,?3) ON CONFLICT(id) DO UPDATE SET key_hash=excluded.key_hash,updated_at=excluded.updated_at",params![account.id,account.key_hash,now()])?;
    tx.execute("DELETE FROM characters WHERE account_id=?1", [&account.id])?;
    {
        let mut insert = tx.prepare("INSERT INTO characters (account_id,name,realm,faction,class,level,updated_at,gold,bags,bank) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)")?;
        for c in characters.values() {
            insert.execute(params![
                account.id,
                c.name,
                c.realm,
                c.faction,
                c.class,
                c.level.map(|v| v as i64),
                c.updated_at.map(|v| v as i64),
                serde_json::to_string(&c.gold).unwrap(),
                c.bags.as_ref().map(|v| serde_json::to_string(v).unwrap()),
                c.bank.as_ref().map(|v| serde_json::to_string(v).unwrap())
            ])?;
        }
    }
    {
        let mut insert = tx.prepare("INSERT INTO trades (account_id,name,realm,at,side,item,count,price,fee,copy,item_key,party) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12) ON CONFLICT (account_id,name,realm,at,side,item,count,price,fee,copy) DO UPDATE SET item_key=COALESCE(item_key,excluded.item_key),party=COALESCE(party,excluded.party)")?;
        let mut copies: BTreeMap<_, i64> = BTreeMap::new();
        // Per character, its oldest trade in the upload and every trade it
        // holds, as the key the table stores it under.
        let mut held: BTreeMap<(&str, &str), (i64, BTreeSet<TradeKey>)> = BTreeMap::new();
        for t in &account.trades {
            let copy = copies
                .entry((
                    &t.name, &t.realm, t.at, &t.side, &t.item, t.count, t.price, t.fee,
                ))
                .or_insert(0);
            insert.execute(params![
                account.id,
                t.name,
                t.realm,
                t.at as i64,
                t.side,
                t.item,
                t.count as i64,
                t.price as i64,
                t.fee as i64,
                *copy,
                t.item_key,
                t.party
            ])?;
            let (oldest, keys) = held
                .entry((&t.name, &t.realm))
                .or_insert((t.at as i64, BTreeSet::new()));
            *oldest = (*oldest).min(t.at as i64);
            keys.insert((
                t.at as i64,
                t.side.clone(),
                t.item.clone(),
                t.count as i64,
                t.price as i64,
                t.fee as i64,
                *copy,
            ));
            *copy += 1;
        }
        // The addon prunes its oldest trades and the sync agent sends the
        // newest, so an upload holds each character's trades from its oldest
        // one on. A trade stored from then on that the upload no longer
        // holds was taken off by the addon, such as a sale bought back or
        // booked twice, and goes. Older trades stay.
        let mut stored = tx.prepare("SELECT at,side,item,count,price,fee,copy FROM trades WHERE account_id=?1 AND name=?2 AND realm=?3 AND at>=?4")?;
        let mut delete = tx.prepare("DELETE FROM trades WHERE account_id=?1 AND name=?2 AND realm=?3 AND at=?4 AND side=?5 AND item=?6 AND count=?7 AND price=?8 AND fee=?9 AND copy=?10")?;
        for ((name, realm), (oldest, keys)) in &held {
            let gone = stored
                .query_map(params![account.id, name, realm, oldest], |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        r.get(4)?,
                        r.get(5)?,
                        r.get(6)?,
                    ))
                })?
                .collect::<rusqlite::Result<Vec<TradeKey>>>()?
                .into_iter()
                .filter(|key| !keys.contains(key));
            for (at, side, item, count, price, fee, copy) in gone {
                delete.execute(params![
                    account.id, name, realm, at, side, item, count, price, fee, copy
                ])?;
            }
        }
    }
    if let Some(fingerprint) = &input.uploader {
        tx.execute(
            "INSERT INTO account_identities (account_id,identity_hash,first_seen) SELECT ?1,battlenet_identity,?3 FROM upload_identities WHERE fingerprint=?2 AND battlenet_identity IS NOT NULL ON CONFLICT DO NOTHING",
            params![account.id, fingerprint, now()],
        )?;
    }
    tx.commit()?;
    Ok(Reply::json(
        json!({"stored":true,"characters":characters.len()}),
    ))
}
