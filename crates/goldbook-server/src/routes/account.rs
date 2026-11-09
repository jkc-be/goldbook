use crate::{App, Error, Input, Reply, Result, SESSION_SECONDS, hash, now};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde_json::{Value, json};
use subtle::ConstantTimeEq;

// The IDs linked with ?1, the ID their group is kept under.
const GROUP: &str = "SELECT id FROM accounts WHERE COALESCE(owner_id,id)=?1";
// The IDs that installs of the player ?1 uploaded, each with its linked group.
const PLAYER_GROUPS: &str = "SELECT id FROM accounts WHERE COALESCE(owner_id,id) IN (SELECT COALESCE(a.owner_id,a.id) FROM accounts a JOIN account_identities ai ON ai.account_id=a.id WHERE ai.identity_hash=?1)";
pub(crate) fn cookie(input: &Input, token: &str, age: i64) -> (&'static str, String) {
    (
        "set-cookie",
        format!(
            "goldbook_session={token}; HttpOnly; SameSite=Strict; Path=/; Max-Age={age}{}",
            if input.secure { "; Secure" } else { "" }
        ),
    )
}
// The ID in `body` and its key hash, if the key is right, else `refused`.
// Wrong keys count against the login limits, whether logging in or linking.
fn verify(
    input: &Input,
    app: &App,
    db: &Connection,
    body: &Value,
    refused: u16,
) -> Result<(String, String)> {
    let id = goldbook_core::normalize_code(body["id"].as_str().unwrap_or(""));
    let key = goldbook_core::normalize_code(body["key"].as_str().unwrap_or(""));
    let well_formed = id.len() == 8 && key.len() == 20;
    let now = now();
    let wait = app.logins.lock().unwrap().begin(
        well_formed.then_some(id.as_str()),
        input.client.as_deref(),
        now,
    );
    if wait > 0 {
        let minutes = (wait + 59) / 60;
        return Err(Error::new(
            429,
            format!(
                "too many attempts, try again in {minutes} minute{}",
                if minutes == 1 { "" } else { "s" }
            ),
        ));
    }
    let stored: Option<String> = if well_formed {
        db.query_row("SELECT key_hash FROM accounts WHERE id=?1", [&id], |r| {
            r.get(0)
        })
        .optional()?
    } else {
        None
    };
    let calculated = goldbook_core::key_hash(&key);
    let matches = calculated.as_bytes().ct_eq(
        stored
            .as_deref()
            .unwrap_or("0000000000000000000000000000000000000000000000000000000000000000")
            .as_bytes(),
    );
    let Some(stored) = stored.filter(|_| bool::from(matches)) else {
        return Err(Error::new(refused, "wrong ID or key"));
    };
    app.logins
        .lock()
        .unwrap()
        .succeed(&id, input.client.as_deref(), now);
    Ok((id, stored))
}
pub(super) fn authenticate(
    input: &Input,
    app: &App,
    db: &mut Connection,
    body: Value,
    // From the desktop app: the website's view to send the browser on to.
    desktop: Option<&str>,
) -> Result<Reply> {
    let (id, stored) = verify(input, app, db, &body, 401)?;
    let now = now();
    let token = URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>());
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute("DELETE FROM sessions WHERE expires_at<=?1", [now])?;
    let inserted = tx.execute("INSERT INTO sessions (token_hash,account_id,expires_at) SELECT ?1,id,?3 FROM accounts WHERE id=?2 AND key_hash=?4",params![hash(&token),id,now+SESSION_SECONDS,stored])?;
    tx.commit()?;
    if inserted == 0 {
        return Err(Error::new(401, "wrong ID or key"));
    }
    let mut r = Reply::json(json!({"id":id}));
    r.headers.push(cookie(input, &token, SESSION_SECONDS));
    if let Some(view) = desktop {
        r.status = 303;
        r.headers.push(("location", format!("../#{view}")));
        r.headers.push(("cache-control", "no-store".into()));
    }
    Ok(r)
}
// Who a website session belongs to: an ID logged in with its key, with the ID
// its group is kept under, or a player signed in with Battle.net.
pub(super) enum Viewer {
    Account { id: String, owner: String },
    Player { identity: String },
}
impl Viewer {
    pub(super) fn of(input: &Input, db: &Connection) -> Result<Self> {
        let token = hash(input.cookie());
        let account = db.query_row(
            "SELECT a.id,COALESCE(a.owner_id,a.id) FROM sessions s JOIN accounts a ON a.id=s.account_id WHERE s.token_hash=?1 AND s.expires_at>?2",
            params![token, now()],
            |r| Ok(Self::Account { id: r.get(0)?, owner: r.get(1)? }),
        ).optional()?;
        if let Some(account) = account {
            return Ok(account);
        }
        let player: Option<(String, bool)> = db.query_row(
            "SELECT s.identity_hash,i.blocked_at IS NOT NULL FROM battlenet_web_sessions s JOIN battlenet_identities i ON i.identity_hash=s.identity_hash WHERE s.token_hash=?1 AND s.expires_at>?2",
            params![token, now()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        ).optional()?;
        // A block signs the player out, so that the website offers the login
        // again; lifting it lets the session back in.
        match player {
            Some((_, true)) => Err(Error::new(401, "this player is blocked")),
            Some((identity, false)) => Ok(Self::Player { identity }),
            None => Err(Error::new(401, "not logged in")),
        }
    }
    // The IDs whose characters and trades the viewer sees, as a query of ?1, and ?1.
    pub(super) fn visible(&self) -> (&'static str, &str) {
        match self {
            Self::Account { owner, .. } => (GROUP, owner),
            Self::Player { identity } => (PLAYER_GROUPS, identity),
        }
    }
    // The ID the viewer logged in with, null for a player, and the other IDs it
    // sees, by ID.
    pub(super) fn ids(&self, db: &Connection) -> Result<(Value, Vec<String>)> {
        let (visible, key) = self.visible();
        let mut stmt = db.prepare(&format!("{visible} ORDER BY id"))?;
        let mut ids: Vec<String> = stmt
            .query_map([key], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(match self {
            Self::Account { id, .. } => {
                ids.retain(|other| other != id);
                (json!(id), ids)
            }
            Self::Player { .. } => (Value::Null, ids),
        })
    }
}
// Links the ID in the body with the session's, and with that every ID either
// was linked with.
pub(super) fn link(input: &Input, app: &App, db: &mut Connection) -> Result<Reply> {
    let Viewer::Account { id, .. } = Viewer::of(input, db)? else {
        return Err(Error::new(
            403,
            "Battle.net sign-in already shows the IDs your installs uploaded; log in with an ID and key to link another",
        ));
    };
    let (other, _) = verify(input, app, db, &input.json()?, 403)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let owner_of = |id: &str| -> rusqlite::Result<String> {
        tx.query_row(
            "SELECT COALESCE(owner_id,id) FROM accounts WHERE id=?1",
            [id],
            |r| r.get(0),
        )
    };
    let (owner, joining) = (owner_of(&id)?, owner_of(&other)?);
    if joining != owner {
        tx.execute(
            "UPDATE accounts SET owner_id=?1 WHERE COALESCE(owner_id,id)=?2",
            [&owner, &joining],
        )?;
    }
    let (_, linked) = Viewer::Account { id, owner }.ids(&tx)?;
    tx.commit()?;
    Ok(Reply::json(json!({ "linked": linked })))
}
