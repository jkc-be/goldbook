use anyhow::{Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Serialize;
use std::{
    collections::HashSet,
    path::Path,
    time::{Duration, SystemTime},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    task::JoinHandle,
};

#[derive(Serialize)]
pub struct GameLogin {
    pub id: String,
    pub label: String,
    #[serde(skip)]
    pub key: String,
}

pub fn game_logins(wow_dir: &Path) -> Vec<GameLogin> {
    let mut found = Vec::new();
    for file in goldbook_sync::saved_variables_files(Some(wow_dir)) {
        let login = goldbook_sync::read_saved_variables(&file)
            .and_then(|saved| goldbook_sync::extract_login(&saved));
        if let Ok(Some(login)) = login {
            let modified = file
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(SystemTime::UNIX_EPOCH);
            let account = file
                .parent()
                .and_then(Path::parent)
                .and_then(Path::file_name)
                .unwrap_or_default()
                .to_string_lossy();
            let flavor = file
                .strip_prefix(wow_dir)
                .ok()
                .and_then(|p| p.components().next())
                .map(|p| p.as_os_str().to_string_lossy())
                .unwrap_or_default();
            found.push((
                modified,
                GameLogin {
                    id: login.id,
                    key: login.key,
                    label: format!("{account} ({flavor})"),
                },
            ));
        }
    }
    found.sort_by(|a, b| b.0.cmp(&a.0));
    let mut seen = HashSet::new();
    found
        .into_iter()
        .filter_map(|(_, login)| seen.insert(login.id.clone()).then_some(login))
        .collect()
}

fn html(text: &str) -> String {
    text.replace('&', "&#38;")
        .replace('<', "&#60;")
        .replace('>', "&#62;")
        .replace('"', "&#34;")
        .replace('\'', "&#39;")
}

pub struct Handoff {
    pub url: String,
    task: JoinHandle<()>,
}

impl Drop for Handoff {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub async fn handoff(api: &str, login: GameLogin, lifetime: Duration) -> Result<Handoff> {
    let target =
        goldbook_sync::api_url(&super::settings::normalize_api(api)?, "/api/desktop-login")?;
    let path = format!("/{}", hex::encode(rand::random::<[u8; 32]>()));
    let nonce = STANDARD.encode(rand::random::<[u8; 24]>());
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .context("Goldbook could not open the website login.")?;
    let host = listener.local_addr()?.to_string();
    let url = format!("http://{host}{path}");
    let content = format!(
        r#"<!doctype html><html lang="en"><meta charset="utf-8"><title>Opening Goldbook</title>
<p>Signing in to Goldbook...</p><form method="post" action="{}"><input type="hidden" name="id" value="{}"><input type="hidden" name="key" value="{}"><noscript><button type="submit">Continue to Goldbook</button></noscript></form><script nonce="{nonce}">document.forms[0].submit();</script></html>"#,
        html(target.as_str()),
        html(&login.id),
        html(&login.key)
    );
    let headers = format!("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nReferrer-Policy: origin\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'nonce-{nonce}'; form-action {}; base-uri 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n", content.len(), target.origin().ascii_serialization());
    let task = tokio::spawn(async move {
        let serve = async {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };
                let mut bytes = Vec::new();
                let read = async {
                    while bytes.len() < 8192 && !bytes.ends_with(b"\r\n\r\n") {
                        let mut byte = [0u8; 1];
                        if stream.read(&mut byte).await? == 0 {
                            break;
                        }
                        bytes.push(byte[0]);
                    }
                    Ok::<_, std::io::Error>(())
                };
                if !matches!(
                    tokio::time::timeout(Duration::from_secs(2), read).await,
                    Ok(Ok(()))
                ) {
                    continue;
                }
                let request = String::from_utf8_lossy(&bytes);
                let valid = request.lines().next() == Some(&format!("GET {path} HTTP/1.1"))
                    && request.lines().any(|line| {
                        line.split_once(':').is_some_and(|(name, value)| {
                            name.eq_ignore_ascii_case("host") && value.trim() == host
                        })
                    });
                if !valid {
                    let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
                    continue;
                }
                let _ = stream.write_all(headers.as_bytes()).await;
                let _ = stream.write_all(content.as_bytes()).await;
                let _ = stream.shutdown().await;
                break;
            }
        };
        let _ = tokio::time::timeout(lifetime, serve).await;
    });
    Ok(Handoff { url, task })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn one_use_form_keeps_credentials_out_of_url() {
        let login = GameLogin {
            id: "K7Q2M9PX".into(),
            key: "7KQ2M9PXABCDEFGHJKMN".into(),
            label: "Account".into(),
        };
        let page = handoff(
            "https://example.com/goldbook",
            login,
            Duration::from_secs(10),
        )
        .await
        .unwrap();
        assert!(!page.url.contains("K7Q2M9PX"));
        let client = reqwest::Client::new();
        let wrong = client
            .get(&page.url)
            .header("Host", "evil.example")
            .send()
            .await
            .unwrap();
        assert_eq!(wrong.status(), 404);
        let result = client.get(&page.url).send().await.unwrap();
        assert_eq!(result.headers()["cache-control"], "no-store");
        let text = result.text().await.unwrap();
        assert!(text.contains("https://example.com/goldbook/api/desktop-login"));
        assert!(text.contains("7KQ2M9PXABCDEFGHJKMN"));
        assert!(client.get(&page.url).send().await.is_err());
    }
    #[tokio::test]
    async fn expires_without_opening_browser() {
        let page = handoff(
            "http://localhost:8787",
            GameLogin {
                id: "K7Q2M9PX".into(),
                key: "key".into(),
                label: "Account".into(),
            },
            Duration::from_millis(10),
        )
        .await
        .unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(reqwest::get(&page.url).await.is_err());
    }
}
