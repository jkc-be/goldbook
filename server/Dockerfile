FROM rust:1.99.1-trixie AS build
WORKDIR /app
COPY . .
RUN cargo build --locked --release -p goldbook-server

FROM debian:trixie-slim
RUN apt-get update && apt-get install --no-install-recommends -y ca-certificates curl \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd --gid 10001 goldbook \
  && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin goldbook \
  && mkdir /data && chown goldbook:goldbook /data
COPY --from=build /app/target/release/goldbook-server /usr/local/bin/goldbook-server
USER goldbook
ENV HOST=0.0.0.0 PORT=8787 DATABASE=/data/goldbook.sqlite
EXPOSE 8787
CMD ["goldbook-server"]
