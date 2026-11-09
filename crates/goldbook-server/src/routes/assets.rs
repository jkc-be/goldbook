use crate::Reply;
use sha2::{Digest, Sha256};
use std::{path::Path, sync::LazyLock};

const ASSETS: [(&str, &[u8], &str); 7] = [
    ("app.js", include_bytes!("../../../../web/app.js"), "js"),
    ("theme.js", include_bytes!("../../../../web/theme.js"), "js"),
    (
        "style.css",
        include_bytes!("../../../../web/style.css"),
        "css",
    ),
    (
        "fonts/marcellus-latin-400-normal.woff2",
        include_bytes!("../../../../web/fonts/marcellus-latin-400-normal.woff2"),
        "woff2",
    ),
    (
        "fonts/roboto-condensed-latin-400-normal.woff2",
        include_bytes!("../../../../web/fonts/roboto-condensed-latin-400-normal.woff2"),
        "woff2",
    ),
    (
        "fonts/roboto-condensed-latin-500-normal.woff2",
        include_bytes!("../../../../web/fonts/roboto-condensed-latin-500-normal.woff2"),
        "woff2",
    ),
    (
        "fonts/roboto-condensed-latin-700-normal.woff2",
        include_bytes!("../../../../web/fonts/roboto-condensed-latin-700-normal.woff2"),
        "woff2",
    ),
];
// Cloudflare overrides the origin's cache headers for js and css, so a changed asset needs a new URL.
static INDEX: LazyLock<Vec<u8>> = LazyLock::new(|| {
    let mut index = include_str!("../../../../web/index.html").to_owned();
    for (name, bytes, _) in ASSETS {
        let version = &hex::encode(Sha256::digest(bytes))[..12];
        index = index.replace(&format!("\"{name}\""), &format!("\"{name}?v={version}\""));
    }
    index.into_bytes()
});
// An asset's name with its content version, as the website's pages link it.
pub(crate) fn versioned(name: &str) -> String {
    let (_, bytes, _) = ASSETS
        .iter()
        .find(|(asset, ..)| *asset == name)
        .expect("a known asset");
    format!("{name}?v={}", &hex::encode(Sha256::digest(bytes))[..12])
}
pub(super) fn static_file(web: Option<&Path>, path: &str) -> Option<Reply> {
    let (body, extension) = if let Some(web) = web {
        let web = web.canonicalize().ok()?;
        let path = web.join(if path == "/" {
            "index.html"
        } else {
            path.trim_start_matches('/')
        });
        let file = path.canonicalize().ok()?;
        if !file.starts_with(&web) || !file.is_file() {
            return None;
        }
        (
            std::fs::read(&file).ok()?,
            file.extension()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_owned(),
        )
    } else {
        match path {
            "/" | "/index.html" => (INDEX.clone(), "html".into()),
            _ => {
                let (_, body, extension) = ASSETS
                    .iter()
                    .find(|(name, ..)| path.strip_prefix('/') == Some(*name))?;
                (body.to_vec(), (*extension).into())
            }
        }
    };
    let content_type = match extension.as_str() {
        "html" => "text/html; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "ico" => "image/x-icon",
        "woff2" => "font/woff2",
        "json" => "application/json",
        _ => "application/octet-stream",
    };
    Some(Reply {
        status: 200,
        body,
        content_type,
        headers: vec![("cache-control", "no-cache".into())],
    })
}
