use anyhow::{Result, bail};
use serde_json::{Value, json};
use std::time::Duration;
use url::Url;

pub struct Login {
    pub authorization_url: String,
    pub user_code: String,
    poll_token: String,
    expires_in: Duration,
    interval: Duration,
}

async fn response(mut response: reqwest::Response) -> Result<(u16, Value)> {
    let status = response.status().as_u16();
    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| anyhow::anyhow!("Battle.net sign-in was interrupted. Try again."))?
    {
        if body.len() + chunk.len() > 8192 {
            bail!("The server returned an invalid Battle.net sign-in response.");
        }
        body.extend_from_slice(&chunk);
    }
    let value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    Ok((status, value))
}

pub async fn enabled(api: &str) -> Result<bool> {
    let reply = goldbook_sync::api_client(api, Duration::from_secs(10))?
        .get(goldbook_sync::api_url(api, "/api/auth/battlenet/status")?)
        .send()
        .await
        .map_err(|_| {
            anyhow::anyhow!("Goldbook cannot reach that server. Try again when connected.")
        })?;
    let (status, value) = response(reply).await?;
    match status {
        200 => value["enabled"]
            .as_bool()
            .ok_or_else(|| anyhow::anyhow!("The server returned an invalid sign-in status.")),
        404 => Ok(false),
        _ => {
            bail!("Goldbook could not check this server's Battle.net sign-in settings. Try again.")
        }
    }
}

fn valid_authorization_url(api: &str, target: &str) -> bool {
    let Ok(expected) = goldbook_sync::api_url(api, "/api/auth/battlenet/authorize") else {
        return false;
    };
    let Ok(target) = Url::parse(target) else {
        return false;
    };
    let secure = target.scheme() == "https"
        || (target.scheme() == "http"
            && matches!(
                target.host_str(),
                Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
            ));
    secure
        && target.origin() == expected.origin()
        && target.path() == expected.path()
        && target.username().is_empty()
        && target.password().is_none()
        && target.fragment().is_none()
}

fn secret(value: &Value, name: &str) -> Option<String> {
    value[name]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 512 && !s.chars().any(char::is_control))
        .map(str::to_owned)
}

fn user_code(value: &Value) -> Option<String> {
    value["userCode"]
        .as_str()
        .filter(|code| {
            code.len() == 8
                && code
                    .bytes()
                    .all(|byte| byte.is_ascii_uppercase() || (b'2'..=b'9').contains(&byte))
        })
        .map(str::to_owned)
}

pub async fn start(api: &str) -> Result<Login> {
    let reply = goldbook_sync::api_client(api, Duration::from_secs(10))?
        .post(goldbook_sync::api_url(api, "/api/auth/battlenet/start")?)
        .header("content-type", "application/json")
        .body("{}")
        .send()
        .await
        .map_err(|_| {
            anyhow::anyhow!("Goldbook cannot reach that server to start Battle.net sign-in.")
        })?;
    let (status, value) = response(reply).await?;
    if status != 200 {
        bail!(
            "Battle.net sign-in is unavailable on this server. Ask its administrator to enable it, or try again later."
        );
    }
    let authorization_url = value["authorizationUrl"]
        .as_str()
        .filter(|url| valid_authorization_url(api, url))
        .ok_or_else(|| {
            anyhow::anyhow!("The server returned an invalid Battle.net sign-in address.")
        })?
        .to_owned();
    let poll_token = secret(&value, "pollToken")
        .ok_or_else(|| anyhow::anyhow!("The server returned an invalid sign-in response."))?;
    let user_code = user_code(&value).ok_or_else(|| {
        anyhow::anyhow!("The server returned an invalid Battle.net confirmation code.")
    })?;
    let expires = value["expiresIn"]
        .as_u64()
        .filter(|n| *n > 0)
        .ok_or_else(|| anyhow::anyhow!("The server returned an invalid sign-in expiry."))?;
    let interval = value["interval"]
        .as_u64()
        .filter(|n| *n > 0)
        .ok_or_else(|| anyhow::anyhow!("The server returned an invalid sign-in interval."))?;
    Ok(Login {
        authorization_url,
        user_code,
        poll_token,
        expires_in: Duration::from_secs(expires.min(600)),
        interval: Duration::from_secs(interval.clamp(1, 10)),
    })
}

pub async fn finish(api: &str, login: Login, cancelled: impl Fn() -> bool) -> Result<String> {
    let deadline = tokio::time::Instant::now() + login.expires_in;
    let client = goldbook_sync::api_client(api, Duration::from_secs(10))?;
    loop {
        if cancelled() {
            bail!("Battle.net sign-in was cancelled.");
        }
        if tokio::time::Instant::now() >= deadline {
            bail!("Battle.net sign-in expired. Sign in again.");
        }
        let reply = tokio::time::timeout_at(
            deadline,
            client
                .post(goldbook_sync::api_url(api, "/api/auth/battlenet/poll")?)
                .header("content-type", "application/json")
                .body(json!({"pollToken":login.poll_token}).to_string())
                .send(),
        )
        .await
        .map_err(|_| anyhow::anyhow!("Battle.net sign-in expired. Sign in again."))?
        .map_err(|_| {
            anyhow::anyhow!(
                "Goldbook cannot reach that server to finish Battle.net sign-in. Try again."
            )
        })?;
        let (status, value) = response(reply).await?;
        match status {
            200 => {
                return secret(&value, "sessionToken").ok_or_else(|| {
                    anyhow::anyhow!("The server returned an invalid sign-in response.")
                });
            }
            202 => {}
            410 => bail!("Battle.net sign-in expired. Sign in again."),
            _ => bail!("Battle.net sign-in could not be completed. Sign in again."),
        }
        tokio::time::sleep_until((tokio::time::Instant::now() + login.interval).min(deadline))
            .await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        Json, Router,
        extract::State,
        routing::{get, post},
    };
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    #[tokio::test]
    async fn server_pairing_polls_until_a_goldbook_session_arrives() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let api = format!("http://{}/goldbook", listener.local_addr().unwrap());
        let authorization = format!("{api}/api/auth/battlenet/authorize?request=opaque");
        let polls = Arc::new(AtomicUsize::new(0));
        let app = Router::new()
            .route("/goldbook/api/auth/battlenet/status", get(|| async { Json(json!({"enabled":true})) }))
            .route("/goldbook/api/auth/battlenet/start", post(move |Json(body): Json<Value>| {
                let authorization = authorization.clone();
                async move {
                    assert_eq!(body, json!({}));
                    Json(json!({"authorizationUrl":authorization,"userCode":"ABCD2345","pollToken":"pair-secret","expiresIn":30,"interval":1}))
                }
            }))
            .route("/goldbook/api/auth/battlenet/poll", post(|State(polls): State<Arc<AtomicUsize>>, Json(body): Json<Value>| async move {
                assert_eq!(body, json!({"pollToken":"pair-secret"}));
                if polls.fetch_add(1, Ordering::SeqCst) == 0 {
                    (axum::http::StatusCode::ACCEPTED, Json(json!({})))
                } else {
                    (axum::http::StatusCode::OK, Json(json!({"sessionToken":"goldbook-enrollment-session"})))
                }
            }))
            .with_state(polls.clone());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        assert!(enabled(&api).await.unwrap());
        let login = start(&api).await.unwrap();
        assert_eq!(login.user_code, "ABCD2345");
        assert!(!login.authorization_url.contains("ABCD2345"));
        assert!(
            login
                .authorization_url
                .contains("/goldbook/api/auth/battlenet/authorize?")
        );
        assert_eq!(
            finish(&api, login, || false).await.unwrap(),
            "goldbook-enrollment-session"
        );
        assert_eq!(polls.load(Ordering::SeqCst), 2);
        let login = start(&api).await.unwrap();
        assert!(
            finish(&api, login, || true)
                .await
                .unwrap_err()
                .to_string()
                .contains("cancelled")
        );
        assert_eq!(polls.load(Ordering::SeqCst), 2);
        server.abort();
    }
    #[test]
    fn confirmation_code_is_required_and_has_the_expected_alphabet() {
        assert!(user_code(&json!({})).is_none());
        for invalid in [
            "",
            "ABCD234",
            "ABCD23456",
            "abcd2345",
            "ABCD0123",
            "ABCD23 5",
        ] {
            assert!(user_code(&json!({"userCode":invalid})).is_none());
        }
        assert_eq!(
            user_code(&json!({"userCode":"ABCD2345"})).as_deref(),
            Some("ABCD2345")
        );
    }

    #[test]
    fn browser_address_is_confined_to_the_saved_server() {
        let api = "https://app.example/goldbook";
        assert!(valid_authorization_url(
            api,
            "https://app.example/goldbook/api/auth/battlenet/authorize?request=opaque"
        ));
        for target in [
            "https://evil.example/goldbook/api/auth/battlenet/authorize",
            "https://app.example/other",
            "http://app.example/goldbook/api/auth/battlenet/authorize",
            "https://user@app.example/goldbook/api/auth/battlenet/authorize",
        ] {
            assert!(!valid_authorization_url(api, target));
        }
    }
}
