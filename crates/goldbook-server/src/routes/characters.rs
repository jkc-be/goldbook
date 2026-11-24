use super::{account::Viewer, required};
use crate::{Error, Input, Reply, Result, db};
use rusqlite::Connection;
use serde_json::{Value, json};
use std::collections::BTreeMap;

const CHARACTER_COLUMNS: &str = "name, realm, faction, class, level, updated_at AS updatedAt";
// The viewer's characters, each one as merged from every ID that uploaded it:
// the details of its newest upload, the gold of all of them with the newer
// upload winning an hour both have, and the newest bags and bank. Gold is
// [[time, copper]] by time, bags and bank as uploaded or null.
fn group_characters(
    db: &Connection,
    viewer: &Viewer,
    filter: &str,
    params: &[&dyn rusqlite::ToSql],
) -> Result<Vec<Value>> {
    let (visible, key) = viewer.visible();
    let rows = db::query(
        db,
        &format!(
            "SELECT {CHARACTER_COLUMNS},gold,bags,bank FROM characters WHERE account_id IN ({visible}){filter} ORDER BY updated_at NULLS FIRST"
        ),
        &[&[&key as &dyn rusqlite::ToSql], params].concat(),
    )?;
    let decode = |text: &Value| -> Result<Value> {
        text.as_str().map_or(Ok(Value::Null), |text| {
            serde_json::from_str(text).map_err(|e| Error::from(anyhow::Error::from(e)))
        })
    };
    let mut merged: BTreeMap<(String, String), (Value, BTreeMap<u64, u64>)> = BTreeMap::new();
    for mut row in rows {
        let key = (
            row["name"].as_str().unwrap().to_owned(),
            row["realm"].as_str().unwrap().to_owned(),
        );
        let gold: Vec<(u64, u64)> = serde_json::from_value(decode(&row["gold"])?)
            .map_err(|e| Error::from(anyhow::Error::from(e)))?;
        let (bags, bank) = (decode(&row["bags"])?, decode(&row["bank"])?);
        let (character, hours) = merged
            .entry(key)
            .or_insert_with(|| (Value::Null, BTreeMap::new()));
        hours.extend(gold);
        for (name, container) in [("bags", bags), ("bank", bank)] {
            let held = &character[name];
            row[name] = if container.is_null() || held["at"].as_u64() > container["at"].as_u64() {
                held.clone()
            } else {
                container
            };
        }
        *character = row;
    }
    Ok(merged
        .into_values()
        .map(|(mut character, hours)| {
            character["gold"] = json!(hours.into_iter().collect::<Vec<_>>());
            character
        })
        .collect())
}
pub(super) fn characters(input: &Input, db: &Connection) -> Result<Reply> {
    let viewer = Viewer::of(input, db)?;
    let mut characters = group_characters(db, &viewer, "", &[])?;
    for c in &mut characters {
        let object = c.as_object_mut().unwrap();
        object.remove("bags");
        object.remove("bank");
        let gold = object["gold"]
            .as_array()
            .unwrap()
            .last()
            .map_or(Value::Null, |point| point[1].clone());
        object.insert("gold".into(), gold);
    }
    characters.sort_by(|a, b| {
        b["gold"]
            .as_u64()
            .cmp(&a["gold"].as_u64())
            .then_with(|| a["name"].as_str().cmp(&b["name"].as_str()))
            .then_with(|| a["realm"].as_str().cmp(&b["realm"].as_str()))
    });
    let (id, linked) = viewer.ids(db)?;
    Ok(Reply::json(
        json!({"id":id,"linked":linked,"characters":characters}),
    ))
}
fn container(mut found: Value) -> Result<Value> {
    if found.is_null() {
        return Ok(found);
    }
    let rows = found["rows"]
        .as_array_mut()
        .ok_or_else(|| Error::new(500, "internal error"))?;
    rows.sort_by(|a, b| b["value"].as_u64().cmp(&a["value"].as_u64()));
    // 1,000 maximum-safe integers fit in u64, but exceed exact JSON doubles.
    let total: u64 = rows.iter().map(|r| r["value"].as_u64().unwrap_or(0)).sum();
    found["total"] = json!(total);
    Ok(found)
}
pub(super) fn character(input: &Input, db: &Connection) -> Result<Reply> {
    let viewer = Viewer::of(input, db)?;
    let name = required(input, "name")?;
    let realm = required(input, "realm")?;
    let mut c = group_characters(db, &viewer, " AND name=?2 AND realm=?3", &[&name, &realm])?
        .pop()
        .ok_or_else(|| Error::new(404, "no such character"))?;
    c["bags"] = container(c["bags"].take())?;
    c["bank"] = container(c["bank"].take())?;
    Ok(Reply::json(c))
}
// The viewer's trades that are not hidden, newest first, or one character's
// with name and realm. A trade that more than one ID uploaded counts once.
pub(super) fn trades(input: &Input, db: &Connection) -> Result<Reply> {
    let viewer = Viewer::of(input, db)?;
    let (visible, key) = viewer.visible();
    let name = input.query.get("name").map(String::as_str).unwrap_or("");
    let realm = if name.is_empty() {
        ""
    } else {
        required(input, "realm")?
    };
    let rows = db::query(
        db,
        &format!(
            "SELECT t.name,t.realm,t.at,t.side,t.item,t.itemKey,i.quality,t.count,t.price,t.fee,t.party FROM (SELECT name,realm,at,side,item,MAX(item_key) AS itemKey,count,price,fee,copy,MAX(party) AS party FROM trades WHERE account_id IN ({visible}) AND hidden=0 AND (?2='' OR (name=?2 AND realm=?3)) GROUP BY name,realm,at,side,item,count,price,fee,copy) t LEFT JOIN items i ON i.item_key=t.itemKey ORDER BY t.at DESC,t.name,t.realm,t.item,t.copy"
        ),
        &[&key, &name, &realm],
    )?;
    Ok(Reply::json(json!({"trades": rows})))
}
