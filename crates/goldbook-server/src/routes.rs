mod account;
mod assets;
mod characters;
mod market;
mod uploads;

use crate::{App, Error, Input, Reply, Result, db, hash};
use account::{authenticate, link};
use assets::static_file;
use axum::http::Method;
use characters::{character, characters, trades};
use market::{deals, export, history, movers, prices, sellers, trends};
use serde_json::{Value, json};
use uploads::{
    register_installation, upload_account, upload_scan, upload_seller_batch, upload_sellers,
};

pub(crate) use account::cookie;
pub(crate) use assets::versioned;

pub(super) fn respond(input: Input, app: &App) -> Result<Reply> {
    if input.path.starts_with("/api/auth/battlenet/") {
        return crate::oauth::respond(&input, app);
    }
    let route = (input.method.as_str(), input.path.as_str());
    if !matches!(
        route,
        (
            "POST",
            "/api/scans"
                | "/api/sellers/batch"
                | "/api/sellers"
                | "/api/account"
                | "/api/login"
                | "/api/desktop-login"
                | "/api/logout"
                | "/api/link"
                | "/api/installations"
        ) | (
            "GET",
            "/api/realms"
                | "/api/professions"
                | "/api/sellers"
                | "/api/prices"
                | "/api/deals"
                | "/api/movers"
                | "/api/history"
                | "/api/trends"
                | "/api/export"
                | "/api/account"
                | "/api/character"
                | "/api/trades"
        )
    ) {
        if (input.method == Method::GET || input.method == Method::HEAD)
            && let Some(reply) = static_file(app.config.web_dir.as_deref(), &input.path)
        {
            return Ok(reply);
        }
        return Err(Error::new(404, "not found"));
    }
    let mut db = db::connect(&app.config.database)?;
    match route {
        ("POST", "/api/installations") => register_installation(&input, app, &mut db),
        ("POST", "/api/scans") => upload_scan(&input, app.config.auctions.is_some(), &mut db),
        ("POST", "/api/sellers") => upload_sellers(&input, &mut db),
        ("POST", "/api/sellers/batch") => upload_seller_batch(&input, &mut db),
        ("GET", "/api/sellers") => sellers(&input, &db),
        ("POST", "/api/account") => upload_account(&input, &mut db),
        ("POST", "/api/login") => authenticate(&input, app, &mut db, input.json()?, None),
        ("POST", "/api/desktop-login") => {
            let body = std::str::from_utf8(&input.body)
                .map_err(|_| Error::new(400, "invalid desktop login"))?;
            if body.split('&').any(|p| !p.contains('=')) {
                return Err(Error::new(400, "invalid desktop login"));
            }
            let fields: Vec<_> = url::form_urlencoded::parse(body.as_bytes()).collect();
            // The app names the website's view to open in the query; the
            // website has views of a few lowercase letters. Without one, as
            // from an app before 0.2.4, #characters, which the website now
            // sends on to Gold.
            let view = input
                .query
                .get("view")
                .map(String::as_str)
                .filter(|view| {
                    (1..=32).contains(&view.len()) && view.bytes().all(|b| b.is_ascii_lowercase())
                })
                .unwrap_or("characters");
            // An app signed in with Battle.net sends its session instead of an ID and key.
            if let [(name, session)] = fields.as_slice()
                && name == "session"
            {
                return crate::oauth::desktop_login(&input, app, &mut db, session, view);
            }
            if fields.len() != 2
                || !fields.iter().any(|(k, _)| k == "id")
                || !fields.iter().any(|(k, _)| k == "key")
            {
                return Err(Error::new(400, "invalid desktop login"));
            }
            let body: serde_json::Map<String, Value> = fields
                .into_iter()
                .map(|(k, v)| (k.into_owned(), Value::String(v.into_owned())))
                .collect();
            authenticate(&input, app, &mut db, Value::Object(body), Some(view))
        }
        ("POST", "/api/link") => link(&input, app, &mut db),
        ("POST", "/api/logout") => {
            let token = hash(input.cookie());
            db.execute("DELETE FROM sessions WHERE token_hash=?1", [&token])?;
            db.execute(
                "DELETE FROM battlenet_web_sessions WHERE token_hash=?1",
                [&token],
            )?;
            let mut r = Reply::json(json!({}));
            r.headers.push(cookie(&input, "", 0));
            Ok(r)
        }
        // One row per house and faction, listed under `realm`: a house name
        // maps to itself, so what is listed here answers `?realm=` as well.
        ("GET", "/api/realms") => Ok(Reply::json(
            json!({"realms":db::query(&db,"SELECT house AS realm,faction,MAX(region) AS region,COUNT(*) AS scans,MAX(scanned_at) AS lastScan FROM scans GROUP BY house,faction ORDER BY lastScan DESC",&[])?}),
        )),
        ("GET", "/api/professions") => Ok(Reply::json(
            json!({"professions": goldbook_core::professions()}),
        )),
        ("GET", "/api/prices") => prices(&input, &db),
        ("GET", "/api/deals") => deals(&input, &db),
        ("GET", "/api/movers") => movers(&input, &db),
        ("GET", "/api/history") => history(&input, &db),
        ("GET", "/api/trends") => trends(&input, &db),
        ("GET", "/api/export") => export(&input, &db),
        ("GET", "/api/account") => characters(&input, &db),
        ("GET", "/api/character") => character(&input, &db),
        ("GET", "/api/trades") => trades(&input, &db),
        _ => unreachable!(),
    }
}
fn required<'a>(input: &'a Input, name: &str) -> Result<&'a str> {
    input
        .query
        .get(name)
        .map(String::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| Error::new(400, format!("{name} is required")))
}
