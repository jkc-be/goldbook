use goldbook_server::{Config, Poller, router};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = Config::from_env()?;
    let host = config.host.clone();
    let port = config.port;
    let auctions = config.auctions.clone();
    let database = config.database.clone();
    let app = router(config)?;
    if let Some(auctions) = auctions {
        // Off the async runtime, where a blocking HTTP client must not be built or dropped.
        std::thread::Builder::new()
            .name("battlenet-auctions".into())
            .spawn(move || match Poller::new(auctions, database) {
                Ok(poller) => poller.run(),
                Err(error) => eprintln!("battlenet auctions: not started: {error:#}"),
            })?;
    }
    let listener = tokio::net::TcpListener::bind((host.as_str(), port)).await?;
    eprintln!("Goldbook listening on {}", listener.local_addr()?);
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .with_graceful_shutdown(async {
        #[cfg(unix)]
        {
            let mut term =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                    .expect("install SIGTERM handler");
            tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = term.recv() => {} }
        }
        #[cfg(not(unix))]
        let _ = tokio::signal::ctrl_c().await;
    })
    .await?;
    Ok(())
}
