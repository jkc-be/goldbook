# Goldbook

Desktop app, server, web UI, and addon source for [jkc-be/goldbook](https://github.com/jkc-be/goldbook).
Copyright (c) 2026 jkc-be. [All rights reserved](LICENSE).

An auction house price tracker for World of Warcraft. It scans the auction
house in game, shows prices in tooltips and a searchable window, and builds a
price history in a database on your own server, with a web UI.

This public repository is the upstream for the addon, desktop app, sync CLI,
server, and web UI. The addon-only distribution is
[jkc-be/goldbook-addon](https://github.com/jkc-be/goldbook-addon). Its approved
mirror workflow copies `addon/` from this repository. Make addon changes here.

An addon cannot open network connections. The game only writes addon data to
disk, in a `SavedVariables` file, on `/reload` and on logout. Goldbook
therefore uses these components:

| Part | Folder | What it does |
|---|---|---|
| Addon | `addon/Goldbook`, `addon/tests` | Scans, stores prices, queues each scan in `SavedVariables`. Mirrored to the public repository |
| Desktop app | `desktop/src-tauri`, `desktop/ui` | Tauri 2 companion with a Rust backend. Installs the addon and uploads scans |
| Terminal sync | `crates/goldbook-sync` | Rust CLI and the sync library used by the desktop app |
| Server | `crates/goldbook-server`, `server`, `web` | Rust API server, SQLite migrations, deployment configuration, and browser UI |

`crates/goldbook-core` defines and validates the shared upload contract. The addon
format, HTTP routes, and SQLite schema are compatible with the previous version.
The browser UI stays in HTML, CSS, and JavaScript. Node.js is only desktop build
tooling. Python is only verification and deployment tooling.

## Test changes locally

Run the full automated suite without an OVH connection or production database:

```sh
make test
```

Install Rust 1.99.1, Python 3.11 or newer, LuaJIT, curl and the Docker Compose
CLI first. The suite needs neither Node.js nor a running Docker daemon. `npm test` runs the same command. `make check`
also runs Rust formatting and clippy checks, and runs in the Check workflow on
pull requests and pushes to main. Installer builds remain manual.

The suite covers the simulated WoW addon, Rust protocol and API tests, sync
retries, SQLite migrations, authentication and ownership, price filters,
sellers and trade history, and deployment tooling unit tests. HTTP integration
tests start the real server on loopback with a fresh temporary SQLite database
and generated game data. Battle.net tests use a local fake provider. Server
tests override database and upload settings and remove inherited Battle.net,
proxy and web-directory configuration. Deployment tooling tests use fixtures;
the suite does not deploy anything. Cargo may download build dependencies.

The proxy check starts real Traefik 3.7.15, matching OVH, on a random loopback
port. It renders both production Compose proxy configurations with test-only
settings and uses their routing rules, priorities, middleware chains and body
limits. It tests an authenticated batch larger than 64 KiB, both host layouts,
`/goldbook` prefix stripping, authentication, database readback, retries through
the sync executable, and rejection above 20 MiB. A negative control removes
the batch routes and must reproduce HTTP 413.

Traefik uses its file provider to point at the temporary local server, rather
than Docker discovery. TLS and ACME are disabled for these loopback HTTP tests;
production certificates, Docker networking and Cloudflare are not exercised.
The pinned Traefik archive is downloaded once from its official GitHub release,
checked against a committed SHA-256, and cached under `target/test-tools`.
The check fails if prerequisites or the download are unavailable; it never
silently skips proxy coverage. Run it alone after `cargo build --locked` with
`python3 scripts/verify-proxy.py`.

The client compatibility check replays the requests of every app version the
server still supports, recorded under `fixtures/clients/`, against the current
server. [fixtures/clients/README.md](fixtures/clients/README.md) explains the
support floor and how to add a version. Run it alone with
`python3 scripts/verify-client-compatibility.py`.

## Local development

Run the same Goldbook image and Compose stack used on OVH:

```sh
make dev
```

Docker must be running. `npm run dev` and `make sandbox` start this same stack.
It builds `server/Dockerfile` and combines `compose.yaml`,
`compose.traefik.yaml` and `compose.path.yaml` with `compose.local.yaml`.
The local overlay supplies Traefik 3.7.15 with Docker discovery
and the production routing, buffering and rate-limit middleware.
Goldbook has no directly published port; requests go through Traefik.

Use **http://localhost:8080/goldbook** in desktop Settings and for the web UI.
Automatic upload setup is enabled locally; no manual token is needed. These
HTTP routes are derived from the production labels and bind only to loopback.

HTTPS remains available at **https://localhost:8443/goldbook/**. Its dedicated-host equivalent is
**https://goldbook.localhost:8443/**. Local TLS uses Traefik's self-signed
certificate, so the browser shows a certificate warning. ACME, Cloudflare
and production upload credentials are not used locally. The proxy
ports bind only to loopback. The existing desktop app settings are unchanged.

Battle.net sign-in is off locally unless the ignored `server/.env.local`
configures a client. Add `http://localhost:8080/goldbook/api/auth/battlenet/callback`
as a redirect URL of the client in the Battle.net developer portal, then
create the file:

```dotenv
BNET_CLIENT_ID=<client ID>
BNET_CLIENT_SECRET=<client secret>
GOLDBOOK_PUBLIC_URL=http://localhost:8080/goldbook
```

`make dev` refuses any other setting in it, so it never loads upload tokens.
Then, as on the server, uploads need **Sign in with Battle.net** in the app.
Delete the file and run `make dev` again to turn it off.

Data persists in ignored `data/dev/`. For real market data, copy an existing
SQLite database on the first start:

```sh
python3 scripts/dev.py up --database ~/Downloads/goldbook.sqlite
```

This uses SQLite's backup API with the source opened read-only and refuses to
replace an existing local database. No production `.env` or upload credentials
are loaded. The local upload token is `goldbook-local-development`.

Web files are mounted read-only from the checkout, so refresh the browser after
an edit. Run `make dev` again to rebuild and restart after Rust changes.
`make dev-check` verifies both host layouts, HTTPS, authentication and upload
buffering. It creates disposable upload identities to test automatic setup,
but adds no market or account snapshots. `make dev-logs` follows container logs;
`make dev-down` stops the stack and keeps local data. The network and Compose
project are separate from production. The container uses your local UID/GID
so it can write the development bind mount.

CI boots and checks this Docker stack as a separate job. The faster native
integration tests remain available for isolated fixtures; they are not the
local development server. These checks do not automate a live WoW client.

## Get started

This runs everything on your own machine. Nothing leaves it until you
[run the backend on your own server](#run-the-backend-on-your-own-server).

### What you need

- World of Warcraft with the modern auction house API (`C_AuctionHouse`). The
  addon declares interface 16001, the 1.60 "Forever" client. On another client
  version the game lists it as out of date.
- Rust 1.99.1, installed through [rustup](https://rustup.rs).
- For the desktop app, Node.js 22.18 or newer and the
  [Tauri system prerequisites](https://v2.tauri.app/start/prerequisites/).
- For verification, LuaJIT, Python 3.11 or newer, curl and the Docker Compose CLI.
- A terminal opened in this folder.

### 1. Install the tools

```sh
cargo build --locked
npm ci  # only needed for the desktop app
```

### 2. Install the addon

Quit the game first, or restart it afterwards. The game only looks for new
addons when it starts, so `/reload` is not enough the first time.

```sh
cargo run -p goldbook-sync -- install
```

Run it again after changing the addon's code. Then `/reload` is enough, also
when the update adds files.

This copies `addon/Goldbook` into `Interface/AddOns` of every installed game
flavor. On macOS it looks in `/Applications/World of Warcraft`. On Windows it
looks in `Program Files (x86)\World of Warcraft`, then `Program Files`. On
Linux it looks through Wine (`~/.wine`), Lutris (`~/Games`), Bottles, and
Steam Proton, including Ubuntu's `~/.steam` and Fedora's
`~/.local/share/Steam`. For any other place, pass the folder:

```sh
cargo run -p goldbook-sync -- install --wow "/path/to/World of Warcraft"
```

When you log in, chat says `Goldbook loaded. Type /gb for commands.` and a
gold coin button sits on the edge of the minimap. Goldbook is also in the AddOns
list (Esc, AddOns) under **Auctions**, and under Options, AddOns.

### 3. Start the API and the web UI

```sh
SELF_REGISTRATION=true UPLOAD_TOKEN=dev-token,friend-token cargo run -p goldbook-server
```

The server creates `data/goldbook.sqlite` on its first start, registers the
app's uploads by itself, and accepts terminal uploads with the token
`dev-token`. Leave it running and open
<http://localhost:8787>. It says that no scans have been uploaded yet.

### 4. Sync

Open the desktop app:

```sh
npm run desktop
```

The window's rail has the addon's hubs. **Market**, **Inventory** and
**Ledger** show the website's Prices, Bags and Gold inside the app, with the
website's tabs for the rest. Inventory and Ledger sign in with the app's
Battle.net sign-in, or else with the login the game saved. **Settings** holds
the status and settings, and **Log in** at the bottom of the rail signs in
with Battle.net.

Open **Settings** and confirm the game folder. Under **Advanced**, set the
server to `http://localhost:8787`. Click **Save** to install the addon and
start uploading.
**Sync automatically** is on by default. It uploads after each game file write
and checks again every 15 minutes, which you can change. With it off, nothing
uploads until you click **Sync now**.
The default server address is <https://app.jkc-be.com/goldbook>; **Use the
default server** under **Advanced** puts it back. The app sets up uploads by
itself: on a server with Battle.net sign-in after **Sign in with Battle.net**,
and on one without it when the server has `SELF_REGISTRATION=true`. It saves a
separate token for each WoW account and reuses it on later starts. If setup fails while offline,
it retries every minute; **Sync now** retries immediately.
Leave Goldbook running. Closing the window leaves it in the menu
bar on macOS, or the tray on Windows and Linux. Quit from that menu, or from
the Goldbook menu.

Change the game folder from **Settings** in the window, and the server under
its **Advanced** tab. **Sync now** checks for new scans
immediately; the sync icon beside the theme switch at the foot of the rail
does the same from any view. **Open website** signs
you in to the website's Gold as your Battle.net player when the app is signed
in. Otherwise it uses the ID and key saved by the addon: after your first game
login, type `/reload` once so they are available, and if several accounts are
saved, choose which one to open.

After a sync pass whose uploads succeed, the app also downloads the server's
prices and history for each realm your SavedVariables name, including other
players' scans. It writes them to `Interface/AddOns/Goldbook/ServerData.lua`
in each game folder, at most once every 15 minutes, and **Sync now** writes
them again. The game loads the file at login and at `/reload`, and the addon
then takes every price newer than its own and fills the days and hours its
history lacks. Tooltips say "from the server" for those prices. The app never writes SavedVariables. [Server data for the addon](docs/server-data.md) describes
the endpoint, the file, and the rules for using it in the addon.

The desktop app passes the login through a temporary local page. The ID and
key are sent in a form to your chosen server and stay out of URLs and logs.
The browser keeps its normal login session. If the game has not saved a
login yet, Goldbook opens the website's login page instead.
The installed addon's `/gb web` window uses that server address too. Restart
World of Warcraft after changing the server address.

After a scan, type `/reload` or log out. The game writes the scan to disk only
then.

The same upload from a terminal:

```sh
cargo run -p goldbook-sync -- --token dev-token
```

It prints `watching …/SavedVariables/Goldbook.lua` for each game account it
finds and keeps running. If your game is somewhere else, add
`--wow "/path/to/World of Warcraft"`.

Either one uploads the game account's login code and each character's gold,
bags and bank, each time they change. It sends only a hash of the key, never
the key itself. The first upload of a login ID claims that ID for its key, and
the server refuses uploads of the ID with any other key. Right after **New
key** it also sends the old key's hash, so the server accepts the new key.

The desktop app remembers uploads separately for each server in
`~/.config/goldbook/desktop-<server hash>.json`. Switching servers sends the
queued scans and account data to the new server automatically. Switching back
keeps the previous server's history.

The terminal agent uses `~/.config/goldbook/state.json`. When switching its
server, pass `--state` with a new path or move the old file away.

Scan identities include the scan's metadata and prices, so different scans
in the same second stay separate. Retrying the same snapshot does not add
another history entry. On upgrade from timestamp-only IDs, the agent sends
its queued scans again once, including any a same-second collision skipped.
The server recognizes retries of scans it already has.

Seller snapshots upload in batches of up to 100, with an 8 MiB target per
request. A larger individual snapshot is sent alone, subject to the server's
20 MiB body limit. Each batch is validated and stored in one transaction;
the app records it as uploaded only after a successful response. Failed
batches remain queued, and retrying an accepted batch adds no duplicate rows.
The sync state retains the latest 50,000 upload identities so a full addon
queue does not immediately fall out of its upload history.

Batch uploads require the matching server update. Deploy the server before
releasing the new desktop client; older clients can still use individual
snapshot uploads.

### 5. Scan

1. Open the auction house in game.
2. Click **Goldbook scan**, the button above the top right corner of the
   window. Its label shows the progress.
3. When chat says the scan is done, type `/reload`. The game only writes addon
   data to disk on `/reload` and on logout. Chat waits for the item names to
   load first, up to 15 seconds, so that they go up with the scan.
4. Goldbook uploads the scan a few seconds later. The window says so, and the
   terminal agent prints `uploaded <realm>|<faction>|<time>`.
5. Refresh <http://localhost:8787>. Each item shows its lowest price, its
   market value, a line of its lowest price per day over 14 days and the
   change over 7 days. Click an item to see its price history and a link to
   it on Wowhead.

From then on, steps 3 and 4 are all you start before playing.

Click **Ledger** in the rail to see your own characters. Type `/gb web` in
game for your account's ID and key, and log in with them. Case, spaces and
dashes do not matter. **Gold** shows the gold of all your characters and a
row per character, richest first; click a name or choose it in the character
chip for its own gold, today, over 7 and 30 days and on a chart. **Bags**
under Inventory shows what the bags and banks would bring, item by item. The
game saves the bags when you log out or type `/reload`, and the bank as it
was the last time you opened it. A login lasts 30 days.

### Verify without scanning

```sh
npm test
npm run e2e
```

The end-to-end check starts its own Rust server with a disposable database,
uploads the Lua addon's generated fixture through the Rust CLI, and compares
129 HTTP observations with the previous implementation. It includes a realm
called Loadtest with 30 scans of 8,000 items. It removes its test data when done.
See [migration verification](docs/rust-migration.md) for the full procedure.

### If something does not work

| You see | Cause and fix |
|---|---|
| No login message, no minimap button, no **Goldbook scan** button | The addon is not loaded. Restart the game, check the AddOns list, and that `Interface/AddOns/Goldbook/Goldbook.toc` exists |
| `Cannot scan: open the auction house first.` | `/gb scan` only works while the auction house window is open |
| `Cannot scan: a full scan is available again in N min.` | The server allows one full scan per 15 minutes per account, counted from the last one it answered. Use a quick scan |
| `Scan stopped: the auction house stopped responding.` | No answer for 60 seconds, or 3 minutes for the list a full scan asks for. Close and reopen the auction house and scan again |
| `Scan stopped: another search replaced the scan; scan again.` | A search in the auction house window while the scan ran. Scan again and leave the window alone until chat says the scan is done |
| A Lua error popup | The addon has not been run in the live game yet, see [Known limits](#known-limits). The error text names the file and line |
| The agent prints nothing after a scan | The game has not written the file yet. Type `/reload` |
| `No World of Warcraft account folder found.` | Pass `--wow` with the game folder |
| `cargo` is not found | Install Rust with rustup and open a new terminal |
| `upload of … failed: 401 {"error":"invalid upload token"}` | `--token` differs from the server's token: `dev-token` for `UPLOAD_TOKEN=dev-token,friend-token cargo run -p goldbook-server`, `UPLOAD_TOKEN` in `/opt/goldbook/.env` on your server |
| `upload of … failed: 503 {"error":"the upload token is not configured"}` | The server was started without `UPLOAD_TOKEN`. Start it with `UPLOAD_TOKEN=dev-token,friend-token cargo run -p goldbook-server` |
| `upload of … failed: …` | The server is not running, or not at the `--api` address. The agent retries every 15 seconds |
| `… gold[0] must be [time, copper]: …` | The addon, the sync agent and the server keep gold per hour since this version, and one of them is older. Deploy the server again first, then restart the agent, then install the addon again and `/reload` |
| `skipped <realm>|<faction>|<time>: …` | That one scan is damaged in the file. The others still upload |
| `… state.json is unreadable, starting again from an empty one` | The agent recovered by itself. It uploads everything again and the server ignores what it already has |

### Where things are

| What | Where |
|---|---|
| Installed addon | `<World of Warcraft>/_<flavor>_/Interface/AddOns/Goldbook` |
| Prices downloaded from the server | `<World of Warcraft>/_<flavor>_/Interface/AddOns/Goldbook/ServerData.lua` |
| Scans waiting for sync | `<World of Warcraft>/_<flavor>_/WTF/Account/<account>/SavedVariables/Goldbook.lua` |
| Scans the agent has sent | `~/.config/goldbook/state.json` |
| Scans the desktop app has sent | `~/.config/goldbook/desktop-<server hash>.json` |
| Local database | `data/goldbook.sqlite` |
| Server code, database and upload token on your server | `/opt/goldbook/app`, `/opt/goldbook/data`, `/opt/goldbook/.env` |

### Reset a local install

Run `make` or `make help` to list available commands and their options.

Quit Goldbook, the sync CLI, and WoW. Stop a running development server with
`make dev-down`. On macOS or Linux, run:

```sh
make reset-local DRY_RUN=1  # Preview the files and permissions to reset.
make reset-local            # Permanently delete the local data.
```

This deletes desktop settings and credentials, embedded browser sessions and
caches, sync history, and this checkout's `data/` directory, including local
server databases. It also deletes Goldbook SavedVariables and their backups
for every account and character in each detected WoW installation, clears
downloaded addon prices, and removes Goldbook's startup entries. The addon stays
installed. On macOS, the reset also removes `/Applications/Goldbook.app`.
Reinstall the desktop app before testing setup again.

The command checks the default WoW folders and the folder in your saved desktop
settings. Include another installation with `make reset-local WOW="/path/to/World of Warcraft"`.
It also resets the settings file selected by `GOLDBOOK_CONFIG`, when set.

On macOS it runs [`tccutil reset All app.goldbook.desktop`](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos)
to reset Goldbook's privacy permissions. A failed permission reset stops the
command before file deletion. The app is removed after its permissions are reset.
Notification preferences and any permissions granted to your terminal for
development builds need to be reset separately in System Settings.

Remote server data, external browser sessions, and `.env` files stay in place.
Custom CLI state files and databases outside this checkout's `data/` directory
need to be removed separately.

## In game

The Goldbook window has three hubs down its left rail. Each hub has tabs
across the top of the page:

| Hub | Tabs |
|---|---|
| Market | Prices, Deals, Movers |
| Inventory | Bags, Mail |
| Ledger | Gold, Accounting |

Click a hub to open the tab it showed last, or its first tab the first time.
Click a tab to switch to it. Each command below opens its own tab, and so its
hub.

| Action | Result |
|---|---|
| Left click **Goldbook scan**, or `/gb scan` | Quick scan: lowest price and quantity per item |
| Right click **Goldbook scan**, or `/gb scan full` | Full scan: every auction, adds a market value. The server allows one per 15 minutes per account |
| `/gb deals` | What is listed right now below its resale or vendor value. Click a row to search the auction house for it |
| `/gb bags` | Your bags: what to auction, at what price, and what to vendor instead. `/gb sell` opens it too |
| `/gb movers` | The prices that rose and fell most since the day before. Top gains first |
| `/gb gold` | Your account: gold per character, gains, a 30 day chart and net worth |
| `/gb mail [text]`, or open a mailbox | The open mailbox: every mail with its items, sender, days left and gold, and a button that collects the mails shown. See [Mail](#mail) |
| `/gb accounting` | Your revenue and expenses, newest first: auction and vendor sales, purchases, trades with players, mail, repairs, flights and every other gold movement, with what each did to your gold. `/gb trades` opens it too. See [Accounting](#accounting) |
| `/gb items [text]` | Your accounting per item: units bought and sold, the average cost and sale, the profit or loss realized and when the item last moved. See [Accounting](#accounting) |
| Alt+click an item, or `/gb item <link or name>` | The item's price history. Works on items in bags, the bank, chat links, loot, the auction house and the Goldbook lists |
| Shift+click an item at the auction house | Also opens its price history, for an item Goldbook has a price for. Works in the auction house's own lists, in your bags and in addons such as Auctionator, and not while you are writing in chat |
| Click a column header | Sorts the list by that column. Click again to reverse |
| `/gb show [text]`, or left click the minimap button | Price list, filtered by item name |
| `/gb autoscan` | Turns on a quick scan each time the auction house opens, at most every 15 minutes. Off at first |
| `/gb minprofit <gold>` | The profit a resale deal must make. Starts at 10 silver |
| `/gb status` | The addon's version, items priced and scans waiting for sync. The window shows the version beside its title |
| **Reload** at the bottom right of the window | Does a `/reload`, so that the game saves Goldbook's data and Goldbook uploads it |
| `/gb web` | The web page's address, and the ID and key that log you in to its character pages. See [Web login](#web-login) |
| Right click the minimap button | Quick scan, while the auction house is open |
| Drag the minimap button, `/gb minimap` | Moves it, hides or shows it |
| `/gb theme dark`, `/gb theme light`, or the half-filled ring by the window's close button | Draws the window in dark ink, the default, or on light parchment |
| `/gb scale <0.7-1.4>`, or the slider in Options > AddOns > Goldbook | Sizes the window, apart from the game's UI scale. 1 is its normal size |
| **Back to Prices** in an item's history | Returns to the list the item was opened from, with its search, filters, sort and scroll |
| Hover an item | The price lines below. Hold Shift over a stack to price the whole stack |

### Price sources

Every item tooltip gets these lines, as far as they are known:

| Line | Meaning |
|---|---|
| Min buyout | The lowest price in the newest scan that saw the item |
| Market value | A per-unit price from the last full scan that ignores overpriced listings. It takes the cheapest 15% of units, extends to 30% while the price rises by less than 20% per step, and drops prices beyond 1.5 standard deviations |
| Usual over N days | The median of the lowest price on each of the last 14 days the item was seen. Needs 3 days |
| Post at | The price `/gb bags` would post it at. Not shown for goods merchants sell |
| Vendor | What a vendor pays. See [Vendor prices](#vendor-prices) |
| Merchant sells | What a merchant asks for one, or "Sold by merchants" when no merchant selling it was seen yet. See [Goods merchants sell](#goods-merchants-sell) |
| Deal | Shown when the item is a deal right now |

### Vendor prices

Goldbook takes what a vendor pays from the sell price the game's own tooltip
shows, for every item, whether you hold it or not. The item data addons read
with `C_Item.GetItemInfo` is wrong for some items: it says 9s 62c for Rough
Bronze Leggings, while the tooltip and the vendor say 5s 77c.

### Goods merchants sell

Thread, vials, flux, coal, flint and tinder, spices, dyes and class reagents
are sold by merchants in any amount. Listings of them on the auction house
above the merchant's price are a trap: only buyers who do not know the
merchant pay them. Goldbook therefore never counts on reselling them:

- `/gb deals` lists them only as vendor deals, never as resale deals;
- `/gb bags` sends them to the vendor, and the bags and net worth count them at
  what a vendor pays.

Goldbook knows the common ones from the start. It learns the rest at every
merchant you open: each item the merchant sells without limit and for gold
alone, at the lowest price seen.

### How deals are found

A deal is an item in the newest scan that sells for more than it costs:

- **Vendor deal.** The lowest listing is below what a vendor pays. See
  [Vendor prices](#vendor-prices).
- **Resale deal.** Not for [goods merchants sell](#goods-merchants-sell). The
  lowest listing is at most 70% of the resale price, and the
  profit after the 5% auction house cut clears `/gb minprofit`. The resale price
  is today's market value from a full scan, or the median of earlier days once
  there are 3 of them. When both are known the lower one counts. Today's own
  lowest price is left out, so a bargain does not lower the bar it is measured
  against.

After a full scan a deal also says how many units are worth buying and what
buying them all makes, counted over the item's five cheapest price levels.
After a quick scan only the cheapest unit is known. The list is sorted by that
total profit.

Resale deals therefore appear after your first full scan, and get better with
every day you scan. They are estimates: a quick scan cannot tell a bid-only
auction from a buyout, and a price can simply have dropped.

### How the sell price is chosen

`/gb bags` posts one copper under the lowest listing, within limits:

- never below 60% of the normal price, where normal is the usual price, else
  the market value, else the lowest listing;
- never where the cut would leave less than a vendor pays;
- never above twice the normal price;
- when the lowest listing is under that floor, it holds the normal price
  instead of chasing it down.

An item whose lowest listing already pays less than a vendor goes to the
vendor, and so do [goods merchants sell](#goods-merchants-sell). Goldbook
advises; it does not post or buy for you.

### Gold and movers

Goldbook notes each character's gold whenever it changes and keeps the
balance at the end of each hour for 60 days. `/gb gold` states the account day
by day, the way a broker would:

- the total, and the change today (also in percent), over 7 days and 30 days;
- the highest balance, the best day and the worst day on record;
- what your bags would bring in, and the net worth of gold plus bags;
- a line of the total per day for the last 30 days. Hover a day for its total;
- one row per character with its own balance and changes.

It counts all gold, not only auction house trades. A character counts with
its first known balance on the days before Goldbook first saw it, so logging
in an alt is not booked as a gain.

`/gb movers` is the market side: every item in the newest scan whose lowest
price differs from the day before it was last seen, with the change in
percent. It needs two days of scans. Prices under a silver on both days are
left out.

### Mail

When you open a mailbox, the Goldbook window opens on the **Mail** tab of
**Inventory** and closes again with the mailbox. To keep it shut, clear
**Open the Mail view when a mailbox opens** in Options > AddOns > Goldbook.
`/gb mail` opens the view at any time, but it lists mail only while a mailbox
is open. While it is open, **Inventory** in the rail shows how many mails it
holds.

Each row is one mail: its first item in its quality's colour and how many,
`+1 more` when it holds other items too, or its subject when it holds none.
A sale names the item it sold. The tag says what the mail is:

| Tag | The mail |
|---|---|
| Sold | The money from an auction that sold |
| Bought | An item you won at auction |
| Cancelled | An item from an auction you cancelled |
| Expired | An item from an auction that did not sell |
| Other | Anything else: mail from players, the postmaster, COD mail |

The next columns show the sender, the days left before the mail is returned or
deleted (orange at 3 days or less), and the gold it holds in green or the COD
it asks in red. The title counts the mails and items and says how much gold
waits. The segments filter by tag and count each tag; the search box matches
item names, subjects and senders. Click a column header to sort.

**Collect N mails** takes the money and items of the mails shown, so pick a
segment or search first to collect only those. It takes the oldest mail first,
one take at a time, and waits for the mailbox to answer each one. While it
runs, the button reads **Stop**. It skips COD mails and stops when your bags
have no free slot left, when you close the mailbox, or when you click
**Stop**. With full bags it still takes the gold. Chat then says what it took.
The mailbox shows at most 50 mails; the status line says how many more arrive
after you collect some.

Goldbook books auction house sales and purchases from the invoices in the
mailbox as soon as it opens, so collecting does not change your accounting.

### Accounting

Goldbook books where your gold comes from and where it goes, per character,
like a broker's statement. Each entry has a source:

| Source | Booked when |
|---|---|
| Auction sale, Auction purchase | You open a mailbox with the auction house invoice. See below |
| Vendor sale | The item appears in the merchant's buyback list, with what the vendor paid. Buying it back takes the sale off again |
| Merchant purchase | You buy from a merchant, with the item and how many |
| Trade sale, Trade purchase | A trade with a player completes: what you gave and what you got, see below |
| Trade gold in, Trade gold out | A trade moves gold and no items the other way |
| Mail gold in, Mail gold out | You take gold from a player's mail, or send gold, with the subject and the player |
| Cash on delivery | You pay for an item mailed cash on delivery |
| Quest reward | You turn in a quest that pays gold, with its title |
| Looted gold | You loot gold or get your share of a group's, added up per hour |
| Repairs, Postage, Auction deposit, Flight, Training, Talent reset | You pay for them; a flight names where to, training the spell and rank, a deposit the item posted |
| Other income, Other expense | Gold moves and nothing above explains it, added up per hour |

The auction house mails an invoice for each sale and purchase: a sale with
its price and the 5% cut, a purchase with what you paid. Each time you open a
mailbox, Goldbook reads those invoices and books the new ones under the
character whose mailbox it is. Chat says how many it booked. You do not have
to take the mail out first, and opening the mailbox again does not book a
sale twice. The gold you collect from that mail, a bid you placed, and a bid
the auction house returns are not booked again. When the merchant closes,
chat says how many vendor sales it booked.

A trade with a player is booked when the game says "Trade complete". Each
item you gave is a trade sale, each item you got a trade purchase, both with
the player's name. The gold you got is shared over the items you gave in
proportion to their market value, or to their count when one of them has no
market value; the gold you paid is shared over the items you got the same
way. An item given for no gold is a sale at 0. Chat says when a trade is
booked.

Looted gold and other income and expense are added up per character and
hour, and booked when the hour has ended. Until then the view lists the hour
so far.

`/gb accounting` lists the entries, newest first: what the entry is (the
item and how many, or what the gold was for, and the player it went to or
came from), its source, the net (green for revenue after the auction house
cut, red for an expense), the character and when. **All**, **Revenue** and
**Expenses** switch between them. The source and character chips filter the
list, and the search box matches the item, the character, the source and the
player. The cards total the entries shown: revenue, expenses, the net, and
the profit or loss realized on goods both bought and sold, however they were
bought and sold. Buy a Jagged Star of the Eagle for 23s and sell it to a
vendor for 31s, and that is a profit of 8s; sell it for 19s, and a loss of
4s. The Gold view shows the same totals for the last 30 days.

**By item**, the tab after Accounting, or `/gb items`, adds the entries up
per item: units bought and sold, the average cost and the average sale after
the cut, the profit or loss on the units that were both bought and sold, and
when the item last moved. The search box matches the item, and the
profession, item, quality and character chips filter it. The cards total what
was bought and sold, the realized profit and the item that made the most.

Goldbook keeps 180 days and at most 3,000 entries per character, never
dropping one less than 30 days old, so that an invoice still in the mailbox is
not booked again.

On the web page, after the next sync, **Ledger** shows the **Accounting**
of the whole account, or of the character chosen in its chip:

- **Revenue** after the auction house cut, **Expenses**, the **Net** of the
  two, and the **Realized profit** on goods;
- **By item**, a tab of its own: units bought and sold, the average cost and
  the average sale after the cut, and the profit or loss on the units that
  were both bought and sold. Sales count at auction, to vendors and in player
  trades; purchases at auction, from merchants, in player trades and by cash
  on delivery;
- **History**: every entry with its source, such as "Auction sale", "Trade
  sale to Mirelle", "Mail gold in from Mirelle", "Quest reward" or "Repairs",
  and what it added to the gold or took from it. **All**, **Revenue** and
  **Expenses** above it filter the list. It shows the newest 20 until you show
  them all.

Entries between two of your own characters, such as gold mailed to an alt,
show on the account page twice: once as revenue and once as an expense. They
cancel out in the net.

The server keeps every entry it receives, also after the addon drops it,
together with the other player of a trade or mail.

### Price history

Goldbook keeps each item's lowest price, quantity and market value per day for
60 days. Alt+click an item, or type `/gb item` with a link or a name, to see
them:

- one row per day the item was seen, newest first, with the change in percent
  from the day before;
- the newest lowest price and its change over a day, 7 days and 30 days;
- the market value with its age, the usual price, the quantity listed, and the
  lowest and highest price of the last 30 days;
- a line of the lowest price per day for the last 30 days, broken on days the
  item was not seen. Hover a day for that day's prices.

Hover the item's name above the chart for its tooltip, or Shift+click it to
link the item in chat.

A name opens the item with exactly that name, else the first one whose name
contains it. Type in the search box to go back to the price list. Turn Alt+click
off under Options > AddOns > Goldbook if another addon uses it.

### Web login

The first time Goldbook loads, it makes a login for the character pages of
the web page: an ID of 8 characters and a key of 20. The game keeps addon data
per game account on each computer, so one login covers every character of
that account played on that computer.

A second computer makes a login of its own. To see the characters of both
together, log in on the web page with one computer's ID and key, open **Link
another computer** under the characters in **Gold**, and enter the other computer's ID and
key. From then on either login shows the characters of both. A character
played on both shows once, with the gold of both and its newest bags and bank.
Linking a login that is already linked with others brings those along.
Each computer keeps its own key, so **New key** on one logs out only the
browsers that logged in with that computer's key.

On a server with Battle.net sign-in, the login offers **Sign in with
Battle.net** first, and folds the ID and key away under **Log in with an ID
and key instead**. It needs no ID or key: it shows every ID that a Goldbook app
signed in with the same Battle.net account uploaded, and every ID linked with
one of them. An ID counts once the app uploads it after signing in, so after
signing in to the app, let it upload once before signing in on the web page.
Linking is for ID and key logins, so a Battle.net sign-in hides **Link another
computer**. **Log out** in the rail ends either kind of sign-in.

`/gb web` shows the web page's address, the ID and the key, the codes grouped
for reading as `K7Q2-M9PX` and `7KQ2M-9PXAB-CDEFG-HJKMN`. **Show ID and key**
under Options > AddOns > Goldbook opens the same window. Chat text cannot be
copied, so the window shows each in a text box. Click a box to select it, then
press Ctrl+C. On the web page, click **Log in** in the rail. To use your own
server, change `X-Website` in `addon/Goldbook/Goldbook.toc` to its address and
install the addon again.

The key is the password to your character pages. Anyone with the ID and the
key sees the gold, bags and bank of your characters. Goldbook keeps both in
its `SavedVariables` file, and the sync agent uploads only a hash of the key.

The web page knows a login only after the sync agent has uploaded it. After
the first load, type `/reload` or log out with the agent running, then log in
on the web page.

**New key** replaces the key and keeps the ID. Use it when someone else may
know your key. Goldbook asks first, because after the next sync the old key
stops working and every browser logged in with it is logged out. Until that
sync the web page still takes the old key.

At each `/reload` and logout, Goldbook saves what the character pages show:
the character's class and level, and its bags with the advice of `/gb bags`.
Gold comes from the balances `/gb gold` keeps. The game lets an addon read the
bank only while it is open, so Goldbook keeps its contents from the last
visit. Open the bank once on each character to have it on the web page.
Goldbook prices the bags and the bank with the newest prices it has at that
moment.

## Run the backend on your own server

The server runs in Docker on a Linux machine you can reach with `ssh`. That
machine needs Docker with Compose, `rsync` and `openssl`. Deploy from this
folder:

```sh
npm run deploy -- <ssh-host>
```

`<ssh-host>` is anything `ssh` accepts, such as `me@203.0.113.7` or a `Host`
from `~/.ssh/config`. The script copies the Rust workspace and web assets to
`/opt/goldbook/app`, builds the image, starts the container and waits until it
answers. It asks for your `sudo` password if it has to create `/opt/goldbook`,
or if your user cannot run `docker`. At the end it prints the address of the
API and the web UI.

Run the same command again after pulling changes. The database and the token
stay as they are.

To deploy to the OVH server from a clean `main` that matches `origin/main`:

```sh
make deploy
```

It first copies the database to `/opt/goldbook/backups`, because migrations
are not rolled back, then runs the deploy above for `fedora_ovh`. Set
`OVH_HOST=<ssh-host>` for another server. It refuses another branch, local
changes, or a `main` that differs from `origin/main`, because the deploy ships
the files as they are in your checkout; `FORCE=1` skips that check.

The first deploy writes `/opt/goldbook/.env` with a random upload token. To
read it:

```sh
ssh <ssh-host> cat /opt/goldbook/.env
```

The server listens on the machine's Tailscale address when Tailscale is
installed there, and on 127.0.0.1 otherwise, so it is not reachable from the
internet. To change the address or the port, set `GOLDBOOK_BIND` or
`GOLDBOOK_PORT` in `/opt/goldbook/.env` and deploy again. To reach it from the
internet, see [Make it public](#make-it-public).

Then run the agent against it, with the address the deploy printed:

```sh
export GOLDBOOK_TOKEN=$(ssh <ssh-host> "sed -n 's/^UPLOAD_TOKEN=//p' /opt/goldbook/.env | cut -d, -f1")
cargo run -p goldbook-sync -- --api <address>
```

`GOLDBOOK_API` in the environment works too. `--token` also works, but puts
the token in your shell history.

Reading prices needs no token. Uploading needs a token.

The signed-in views of the web page ask for the ID and key that `/gb web`
shows in game. The server stores only a hash of the key. A login lasts 30 days.
Five wrong tries for one ID from one address lock that ID for that address for
15 minutes. Linking another computer's ID counts the same tries.

### Deploy manually from GitHub Actions

Only @jkc-be can start production operations, from `main`, and approve access
to deployment secrets. Open **Actions > Deploy to OVH > Run workflow**. Leave
`verify_only` selected to validate the image and OVH access without replacing
the running service. Uncheck it to deploy, then approve the `production` job.
Pushes and pull requests do not deploy the server automatically.

The workflow builds `ghcr.io/jkc-be/goldbook-server` and calls a restricted SSH
helper on OVH. It validates the GitHub run and image revision, pins the image
digest, and waits for health. A startup failure restores the previous image and
configuration. Database migrations are not rolled back.

For initial setup and the exact permissions, secrets, and approval controls,
see [repository administration](docs/repository-administration.md). Runtime
credentials and the database stay on OVH. Compose changes require a separate
administrator update to the files on the host.

### Make it public

Goldbook goes public through a Traefik that already runs on the server. That
Traefik needs version 3.2 or newer, the Docker provider, an HTTPS entrypoint
and a Let's Encrypt certificate resolver. Goldbook does not start a Traefik of
its own. Its container joins Traefik's Docker network, and labels on the
container tell Traefik to pass requests for the host name to it.

Point the DNS of a host name at the server. Then add these lines to
`/opt/goldbook/.env`, with your own values:

```sh
GOLDBOOK_HOST=gold.example.com
TRAEFIK_NETWORK=infra_default
TRAEFIK_ENTRYPOINT=websecure
TRAEFIK_CERTRESOLVER=letsencrypt
TRUSTED_PROXY=172.19.0.0/16
GOLDBOOK_BIND=127.0.0.1
```

| Line | What it sets |
|---|---|
| `GOLDBOOK_HOST` | The public host name |
| `TRAEFIK_NETWORK` | The Docker network Traefik is on |
| `TRAEFIK_ENTRYPOINT`, `TRAEFIK_CERTRESOLVER` | Traefik's HTTPS entrypoint and its certificate resolver. Without these lines they are `websecure` and `letsencrypt` |
| `TRUSTED_PROXY` | Where Traefik connects from, see below |
| `GOLDBOOK_BIND` | `127.0.0.1` keeps the plain HTTP port on the machine itself, for checks from there. Over plain HTTP the upload token is readable on the network |

To also serve Goldbook at `https://app.jkc-be.com/goldbook/`, add
`GOLDBOOK_PATH_HOST=app.jkc-be.com` to the same env file and deploy again.
The shared host must point to this Traefik server. The deployment adds
`server/compose.path.yaml`, which redirects `/goldbook` to `/goldbook/` and
strips the prefix before forwarding requests. The `GOLDBOOK_HOST` URL stays
available. Copy this Compose file to the server before using Actions to deploy.

For connections from `TRUSTED_PROXY`, the server takes the visitor's address
from the last entry of the `X-Forwarded-For` header and ignores the entries
before it. The proxy must add the address it sees to the end of that header.
Traefik does this by default. Without `TRUSTED_PROXY` every visitor would look
like Traefik and share one limit on wrong logins, so the deploy stops when it
is missing. Set it to Traefik's address or to the range of its network. The
range keeps working when Traefik gets a new address, but it also trusts every
other container on that network. `docker network inspect infra_default` shows
the range under `Subnet` and Traefik's address under `Containers`. Docker's
userland proxy can hand Traefik every IPv6 connection from the network's
gateway, so a visitor whose forwarded address is inside `TRUSTED_PROXY` cannot
be told apart from the others, and the server limits their wrong logins per ID
only, at 200 in 15 minutes.

Deploy again. The deploy then prints `Goldbook: https://gold.example.com`. Use
that address for `--api`.

Traefik limits each visitor to 20 requests a second on average, with bursts of
up to 60. It counts an IPv6 visitor per /64, as the server's login limit does.
It refuses a request body over 64 KB, except on the two upload paths, which
allow 20 MB. It also tells browsers to use only HTTPS for the host name for a
year.

### Let a friend upload

For verified player identities, enable Battle.net sign-in as described below.
Without it, fingerprints remain client claims that can be spoofed.

For automatic desktop setup, set `SELF_REGISTRATION=true` in
`/opt/goldbook/.env` and deploy the server before publishing the client.
Update the remote Compose file too: Actions deployments reuse the Compose
files on the host. This setting allows anyone to register for upload access.
Registration allows 20 attempts per source address every 15 minutes, grouping
IPv6 addresses by /64. Keep the public proxy rate limits enabled.

Users choose their game folder and click **Save**.
The app registers each WoW account, saves its private token, and starts syncing.
An installation that saved a manual token in an earlier version drops it and
registers instead. Revoked account tokens are not replaced automatically.

The account fingerprint is SHA-256 of `goldbook:wow-account:v1:` followed by
the account-folder identifier in ASCII uppercase. The identifier comes from
`WTF/Account/<identifier>/SavedVariables/Goldbook.lua`. The full path and the
unhashed identifier are not sent during registration. Game flavor and local
installation path are excluded so the same account can share credentials
across game versions. A changed identifier produces a different fingerprint.
This is a claimed identity; spoofing it remains possible.

The server stores identities in `upload_identities` and credential hashes in
`upload_tokens`. Upload request logs include `fingerprint=<hash>` so operators
can identify the account to block. On the server, run:

```sh
python3 /opt/goldbook/app/scripts/upload-access.py --database /opt/goldbook/data/goldbook.sqlite list
python3 /opt/goldbook/app/scripts/upload-access.py --database /opt/goldbook/data/goldbook.sqlite block <fingerprint>
python3 /opt/goldbook/app/scripts/upload-access.py --database /opt/goldbook/data/goldbook.sqlite unblock <fingerprint>
```

Copy this script to the host if Actions deployed only the container image.
Blocking takes effect for all tokens belonging to the fingerprint and rejects
new registrations. Other accounts remain active. After unblocking an account
that never obtained a token, click **Sync now** to retry setup. Administrator
tokens in `UPLOAD_TOKEN` are exempt from fingerprint blocks.

To revoke just one credential, set its `revoked_at` to the current Unix
timestamp. Disabling `SELF_REGISTRATION` stops new registrations; existing
account tokens keep working unless revoked or their fingerprint is blocked.
Registration grants upload access only. Character
pages still require the addon's web login, and existing account ownership
checks still apply.

For a private server with registration disabled, provision tokens manually.
Give each friend who uploads a token of their own, so that you can revoke one
without the others. Make one:

```sh
openssl rand -hex 32
```

Add it to `UPLOAD_TOKEN` in `/opt/goldbook/.env`, after a comma, and deploy
again:

```sh
UPLOAD_TOKEN=<your token>,<friend's token>
```

The server accepts any token in the list. Keep your own token first, because
the `export GOLDBOOK_TOKEN` command above takes the first one. To revoke a
token, remove it from the line and deploy again.

The desktop app sets up its own uploads and takes no manual token, so a friend
with a token uploads from a terminal:
`cargo run -p goldbook-sync -- --api https://gold.example.com --token <their token>`.
Setting `GOLDBOOK_TOKEN` instead of `--token` keeps the token out of their
shell history. Their scans go into the same price history as yours. On the
web page they log in with the ID and key from their own `/gb web`, and see
only their own characters.

### Battle.net sign-in

Register a client in the Battle.net developer portal with these values:

- Service URL: `https://app.jkc-be.com/goldbook/`
- Redirect URL: `https://app.jkc-be.com/goldbook/api/auth/battlenet/callback`

Configure all three values in the server's private `/opt/goldbook/.env`:

```dotenv
BNET_CLIENT_ID=<client ID>
BNET_CLIENT_SECRET=<client secret>
GOLDBOOK_PUBLIC_URL=https://app.jkc-be.com/goldbook
SELF_REGISTRATION=true
```

Keep the client secret on the server. The desktop app receives a Goldbook
session, never the client secret or a Battle.net access token. If the client
secret expires, replace it in the environment and recreate the container to
restore new sign-ins. Existing Goldbook upload credentials remain independent.

Copy the updated Compose configuration to the host before deploying through
Actions. Deploy the server before publishing the client update.

In the app, save the game folder and server, then click **Log in** at the
bottom of the rail and **Sign in with Battle.net**. Enter the eight-character
code shown by Goldbook
in the browser page, and continue to Battle.net. Only enter a code from your
own app. Return to Goldbook after signing in. **Cancel sign-in** stops waiting
without changing existing credentials. **Log out** in the rail ends the
Battle.net session in the app and its website view; uploads keep the
credentials they have.

The app saves a server-scoped enrollment session for subsequent WoW account
registrations. Enrollment sessions expire after 30 days; sign in again when
new account registration requires it. New sign-in relinks upload credentials;
first linking an anonymous fingerprint revokes its old tokens. A fingerprint
already linked to another Battle.net identity cannot be claimed again.

The verified identity is the Battle.net account, while WoW folder identifiers
remain client claims. This does not prove ownership of a particular WoW
character. Each account upload from a linked fingerprint records the player
against the uploaded ID, and the website's **Sign in with Battle.net** shows
the player those IDs and the IDs linked with them, beside the addon's ID and
key login. Website sign-in uses the same redirect URL, so the portal needs no
change. Manual administrator tokens remain exempt from the self-service login
gate, and their uploads record no player.

Fingerprint listings include `player_hash` for the linked Battle.net identity.
To manage player blocks on the server:

```sh
python3 /opt/goldbook/app/scripts/upload-access.py --database /opt/goldbook/data/goldbook.sqlite --identity-type battlenet list
python3 /opt/goldbook/app/scripts/upload-access.py --database /opt/goldbook/data/goldbook.sqlite --identity-type battlenet block <player_hash>
python3 /opt/goldbook/app/scripts/upload-access.py --database /opt/goldbook/data/goldbook.sqlite --identity-type battlenet unblock <player_hash>
```

A player block rejects uploads from all linked fingerprints and new enrollment
or token requests for the same verified player. It also remains effective if
the client changes its claimed fingerprint. Disabling OAuth configuration
restores anonymous enrollment, so retain it while relying on verified-player
blocks. Block checks for already linked identities remain effective.

## Develop

```sh
luajit addon/tests/run.lua && luajit addon/tests/scanner.lua
cargo test --locked
cargo fmt --all --check
cargo clippy --locked --all-targets -- -D warnings
cargo build --locked
python3 scripts/verify-migration.py
npm run desktop
npm run desktop:pack
npm run preview
```

`make check` runs the checks of the Check workflow. `make hooks`, once per
clone, makes `git push` run it first. Skip it once with `git push --no-verify`.
`make build` is `npm run desktop:pack` with dependencies installed first,
followed by `make install-addon`, which copies this checkout's addon into every
game in the World of Warcraft folder and keeps each one's `ServerData.lua`
(`make install-addon WOW=/path` for another folder).
`make app` builds only the app without an installer, which is faster and needs
no `rpmbuild` on Linux. `make run` starts the local server stack with `make dev`,
rebuilt from this checkout when it changed, and then the desktop app in
development mode. `make test` and `make clean` do what they say. `make clean`
removes `target/release/bundle`.

The default Cargo workspace builds the protocol, sync CLI, and server. The
Tauri app is a separate workspace member so server builds need no desktop
system libraries. `cargo test --locked -p goldbook-desktop` checks desktop
settings and the one-use browser login handoff. The root `npm test` runs the
full local suite described above.

All four crates use Rust edition 2024 and inherit their minimum Rust version
and shared dependency versions from the root `Cargo.toml`. Local builds and CI
read `rust-toolchain.toml`. When upgrading Rust, update that pin, the workspace
minimum, and the builder image in `server/Dockerfile` together. Commit any
dependency resolution changes in the shared `Cargo.lock`.

The CLI supports `--file`, `--wow`, `--api`, `--token`, `--state`, and `--once`.
Run `cargo run -p goldbook-sync -- --help` for details. It reads `GOLDBOOK_API`
and `GOLDBOOK_TOKEN` when the corresponding option is absent.

`npm run desktop:pack` writes installers under `target/release/bundle`. Build
on the target operating system. The macOS build is ad-hoc signed, not
notarized, so the first launch needs right-click, **Open** (or **Open Anyway** in
System Settings, Privacy & Security). If macOS says the app is damaged, the
download predates ad-hoc signing. Run `xattr -dr com.apple.quarantine /Applications/Goldbook.app`. Node.js runs the Tauri build tool only; the installed app uses Rust
and the operating system's webview.

Installers are built by hand, to save GitHub runner minutes. In **Actions**,
choose **Build macOS**, **Build Windows**, **Build Ubuntu**, or **Build Fedora**.
Click **Run workflow**, select a branch, then click **Run workflow** to build
only that installer. **Build macOS** runs only on `main`, requires the owner's
approval in `release-signing`, and signs the app and DMG with Apple's Developer ID.
Other branches can use the **Check** workflow's installer build for an ad hoc
macOS build. These buttons appear after the workflows reach `main`.
Download the installer from the run's **Artifacts**. Downloads stay available
for 30 days.

Before running **Build macOS** or **Release build**, add these secrets under
**Settings > Environments > release-signing > Environment secrets**:

| Secret | Value |
|---|---|
| `APPLE_CERTIFICATE` | Base64-encoded `.p12` containing the Developer ID Application certificate and its private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password chosen when exporting the `.p12` |
| `APPLE_ID` | Apple account email used for notarization |
| `APPLE_PASSWORD` | An Apple app-specific password, not the account's sign-in password |

In Keychain Access, select **login > My Certificates**, select
**Developer ID Application: jkc (P5339LSR49)** with its private key, and export it
as a password-protected `.p12`. Encode that file with
`openssl base64 -A -in /path/to/Goldbook.p12 -out /path/to/Goldbook-base64.txt`
and save the encoded contents as `APPLE_CERTIFICATE`. Keep the export and
credentials out of the repository and logs. Create the app-specific password at
[account.apple.com](https://account.apple.com/).

The builder uses team `P5339LSR49`, imports the signing key into a temporary
keychain, and deletes the keychain and certificate export when it exits.
It checks the app and DMG signatures, Apple notarization tickets and Gatekeeper
acceptance before uploading artifacts. Missing signing or notarization credentials
fail the build.

Notarization is off for now, because Apple does not yet accept the team for it.
`NOTARIZE: 'false'` in `.github/workflows/desktop.yml` makes the builder sign
without notarizing and skip the notarization and Gatekeeper checks, so macOS
still warns on first launch. [Issue #24](https://github.com/jkc-be/goldbook/issues/24)
tracks turning it back on. The update feed still requires its separate
`TAURI_SIGNING_PRIVATE_KEY` secret in the same protected environment.

To run all checks and build every installer, use **Actions > Check > Run
workflow**. Pull requests and pushes to `main` run the test, local Docker stack, and secret
scan jobs, including the local HTTP checks and sandbox smoke test. Production deployment is a separate
manual workflow.

### Website

The website is laid out and coloured like the addon's window, in the colours
the game shows it in. It opens dark; the half-filled ring in the title bar
switches between the dark and the light window, and the site remembers the
choice. The rail on the left has three hubs, and each hub has tabs at the top
of the page:

| Hub | Tabs | Sign-in |
| --- | --- | --- |
| **Market** | Prices, Deals, Movers | No |
| **Inventory** | Bags | Yes |
| **Ledger** | Gold, Accounting, By item | Yes |

Under **Account** the rail has **Download**. Mail is in game only. Each tab
has its own address, such as `#prices`, `#deals`, `#movers`, `#bags`, `#gold`,
`#accounting` or `#items`. The character pages of earlier versions are gone:
`#characters` opens Gold, and `#character/<name>-<realm>` opens Gold with that
character chosen. The Market tabs show the realm chosen at the top. The other
tabs show the login when you are signed out.

- **Prices** lists the newest scan's prices. See
  [Filter item lists](#filter-item-lists), [Compare item prices](#compare-item-prices)
  and [Order book history](#order-book-history).
- **Deals** lists the resale deals of the newest scan, found as in
  [How deals are found](#how-deals-are-found): at most 70% of the lower of the
  market value the newest scan measured and the median of at least three
  earlier days, for an item merchants do not sell, with at least 10s profit
  after the cut. It differs from `/gb deals` in three ways. Vendor deals are
  left out, because the server has no vendor prices. Profit is per unit,
  because the server keeps no price levels, as after a quick scan in game.
  Only [the goods merchants sell](#goods-merchants-sell) that Goldbook knows
  from the start count, not those your characters found at merchants.
- **Movers** lists the prices that rose, or under **Fallers** fell, since the
  day before each item was last seen, as `/gb movers` does.
- **Bags** lists the items in the bags and banks of all your characters as
  the addon's Bags lists those of the character playing: a row per item with
  its count, the price to post it at, what a vendor pays, its last 7 days,
  what it brings in and where to sell it, with the values your characters
  last saved. Hover an item to see whose bags hold it. Search, the
  profession, item and quality filters and a character filter narrow it.
- **Gold** has the addon's cards for the gold of all your characters, or of
  the one you choose: the total and its high, today, 30 days and net worth.
  Under them are the gold over one week, one month or two months, the
  characters with their gold, today's change and when they last played, and
  the month's accounting. Click a character's name to choose it, and again
  for all of them. Under the characters are the account's ID and **Link
  another computer**.
- **Accounting** lists the entries the addon booked for all your characters,
  with the revenue, expenses, net and realized profit of the entries shown,
  and a search, source and character filters.
- **By item** lists each item your characters bought or sold: the units
  bought and their average cost, the units sold and their average sale after
  the cut, the profit realized on the units both bought and sold, and when it
  last moved, newest first. Its cards total what was bought and sold, the
  realized profit and the best item. A search, the profession, item and
  quality filters and a character filter narrow it.

The tables of Prices, Deals and Movers open an item's price history in
Prices. The server works out Deals and Movers from the lowest price of each
day in the last 60, as the prices it sends the addon.

### Filter item lists

Use **Profession**, **Item type**, and **Quality** above Prices, Deals and
Movers on the website or desktop app. Selecting a profession shows only its materials. Choose **Crafted items** to see its products instead. Filters combine
with item search and sorting; **Clear filters** restores the full list.

The in-game Goldbook window has the same dropdown lists on Prices, Deals,
Sell, and Movers. Shared materials can appear under several professions.
Only items present in the relevant scan or inventory appear in the results.
The bundled Classic catalog uses item IDs rather than names, so it works with
localized item names and suffix variants. Uncatalogued items remain visible
under **All items**. See [catalog provenance](catalog/README.md) for coverage
and the regeneration command.

### Compare item prices

In **Prices**, select an item and use **Compare** in its history, then do
the same for another item such as Copper Ore and Copper Bar. Up to six items share one graph of minimum buyout
per unit for the selected realm and faction. The table below shows each item's
latest price, market value, listed quantity and scan age.

Select an item's name in the legend to remove it. **Refresh** reloads the
observations; changing realm clears the selection. Lines connect recorded
scans, so gaps do not imply a current price or continuous market activity.

### Order book history

Select an item in **Prices** to see its price-history graph above the
**Order book** panel. The book shows buyout prices, quantities, cumulative
depth, available seller names and observation time.

To collect order books with the updated addon, run `/gb scan full` at the
auction house. Every resolved item gets a buyout price ladder, quantities, and
seller names where the game provides them. The completion message reports the
number of books recorded. Type `/reload` or log out with the desktop app running
to save and upload them. `/gb status` shows the number of locally saved books.

Complete item and commodity searches also record books, including searches in
Auctionator. Quick scans and older price scans contain only price summaries;
their full order books cannot be reconstructed.

The web panel shows best ask, price levels, cumulative sell-side depth and the
observation time. WoW auctions do not provide a standing buy-order book.
Bid-only listings are excluded. The graph describes the recorded snapshot,
not a live feed.

The order book groups all buyout listings by unit price, including stock with
unknown sellers. Cumulative units show how much stock is listed at or below
each price. Use **Observation** to review earlier order books.
Named owners are combined at each price, but unnamed owners are not counted
as distinct sellers across listings.

The addon retains up to 10,000 observations and 200,000 offer rows, pruning the
oldest observations and those older than 14 days when a search or full scan is
captured. Offers with the same owner and unit price are combined in full scans.
Sync before reaching those limits to preserve the observations on
the server. Uploaded observations remain in the server database, including
snapshots uploaded before this feature was added. Repeated uploads are
deduplicated. History records completed searches and full scans, not every auction change.

Character names do not identify player accounts, and a snapshot describes
stock at its observation time. Use repeated searches to compare order books.

`npm run preview` draws the simulated addon views as HTML and PNG. It needs
`google-chrome` and ImageMagick's `magick`.

The server reads `HOST`, `PORT`, `DATABASE`, `UPLOAD_TOKEN`, `SELF_REGISTRATION`,
and `TRUSTED_PROXY`. Optional Battle.net sign-in reads `BNET_CLIENT_ID`,
`BNET_CLIENT_SECRET`, and `GOLDBOOK_PUBLIC_URL`. `SELF_REGISTRATION` defaults to
`false`.
Its defaults are `127.0.0.1`, `8787`, and `data/goldbook.sqlite`; there is no
default upload token. On PowerShell, set `$env:UPLOAD_TOKEN = "dev-token"`
before `cargo run -p goldbook-server`. The server embeds the web assets.
Set `WEB_DIR` to a folder to override them during development.

The server applies `server/migrations` once, in name order, on startup. The
Rust port reuses all five existing migrations, their tracking table, and the
same fingerprint calculation. An existing SQLite database needs no export or
reset. Back it up before deploying. A database that predates migration 0005
still upgrades in place and keeps scan IDs and prices.

Existing Electron settings and per-server upload state stay readable. The
Rust sync agent also reads older timestamp-only scan state and remembered
account hashes. It may resend an account after upgrade; the server keeps the
upload idempotent. The addon and its saved-data format are unchanged.

The small Python forced-command deployment helper remains operational tooling.
Production deployment is a separate manual action. Updating the remote Compose
healthcheck to use `curl` is required with the Rust image; `server/deploy.sh`
copies the new configuration. The Actions deployment reuses remote Compose
files, so update those before deploying the Rust image through Actions.

## Known limits

- The addon has been tested against a simulated client only
  (`addon/tests/wowstub.lua`), not yet in the live game. The scan requests,
  the frame layout, the tooltip hook, the Alt+click hook, the bank events,
  the mailbox invoices and copying from the web login boxes are the parts to
  confirm first.
- A quick scan has no market value. After a quick scan the web UI shows the
  market values of the realm's newest full scan and says how old they are. An
  item that scan did not see shows a dash. In game each item keeps its own
  last known market value.
- Days in the web UI's trends and gold changes are UTC days, as in game, so a
  scan or a sale shortly after midnight can count for the day before. The gold
  chart shows local time.
- The auction house cut is taken as 5% everywhere. Deposits are ignored.
- Items with a random suffix are named after their base item until a full scan
  sees them.
- On the 1.60 client an item link does not carry the random suffix where
  classic links do. A full scan matches the link's bonus ids against the
  suffixes a quick scan reported, and leaves out variants it cannot match, so
  that their prices do not mix. Chat says how many. Do a quick scan before a
  full scan.
- Every scan is kept. The database grows by about 0.2 MB per scan of 8,000
  items. The end-to-end check uses a disposable database for its 30
  scans. One such scan a day adds about 75 MB a year.
- Price history keeps 60 days in its own table, so the `SavedVariables` file
  grows by roughly 1 KB per item seen daily. Upgrading from an earlier version
  starts each item's history from its newest day.
- Web search ignores case for ASCII letters only and takes at most 100
  characters.
- Auction sales and purchases come from the auction house invoices in the
  mailbox, so a sale is booked only once its mail arrives and the mailbox is
  opened. A mail that expires or is deleted unopened is never booked. A sale
  is dated by the days its mail has left, which is when the auction house
  sent it. Two identical sales sent within two minutes of each other, where
  the first mail was taken before the second arrived, count as one. A vendor
  sale is noticed through the buyback list, which holds 12 items: with it
  full, selling the same stack as its oldest entry is booked only when the
  gold gained equals that price.
- The game says only that your gold changed, not why. Goldbook books a change
  by what you did within 10 seconds of it, so two things done at once can be
  booked under the wrong source, and a change it cannot explain is other
  income or expense. A sold auction's mail returns its deposit with the sale,
  and that deposit is booked as other income. Gold sent between your own
  characters is mail gold out on one and mail gold in on the other.
  Profit or loss is per item name, and per character when one is chosen, so
  an item bought on one character and sold on another has a cost only with
  all characters shown.

## Source, license, and contributions

This repository contains the desktop, server, web UI, and `addon/` sources.
[jkc-be/goldbook-addon](https://github.com/jkc-be/goldbook-addon) mirrors
`addon/` from this public repository. **Release promote** mirrors each release
through the **Mirror addon** workflow, which requires approval of the
`addon-mirror` environment.
The mirror records its source commit in `upstream.json` and publishes a
`Goldbook-<version>.zip` release asset with `Goldbook/Goldbook.toc` at its root.
The mirror's release workflow uploads that exact ZIP to CurseForge project
`1747971` and, when `WOWINTERFACE_PROJECT_ID` is set, to WoWInterface. Each
destination has its own protected environment approval, API token and release
receipt to prevent repeat uploads of an already recorded ZIP. See
[CurseForge publishing](addon/README.md#publish-to-curseforge) and
[WoWInterface publishing](addon/README.md#publish-to-wowinterface).
Use the release asset for manual installs. GitHub's automatic
**Source code** archives contain an extra repository folder and cannot be
uploaded as an addon. Build the same archive locally with:

```sh
python3 addon/package.py addon/dist
```

Goldbook is source available with [all rights reserved](LICENSE). Public
visibility does not grant an open-source license. See [CONTRIBUTING.md](CONTRIBUTING.md)
for contribution permissions and [SECURITY.md](SECURITY.md) for private reports.
Only @jkc-be controls merges and pushes to `main`; production and signing
credentials require separate approval. See [repository administration](docs/repository-administration.md).

## Client and addon updates

Goldbook checks for updates at startup and every six hours. The Sync tab shows
both update statuses and has a **Check for updates** button. A client update
downloads in the background. Goldbook shows a desktop notification and an
**Update ready** button; choose **Install and restart** to apply it. Linux
package updates may ask for the administrator password.

The client also downloads and installs signed addon updates in the selected
World of Warcraft folder. Type `/reload` afterward, or restart WoW if Goldbook
was not previously installed. Updates replace the Goldbook addon directory;
scans and characters in SavedVariables are preserved. The bundled addon works
when offline, and a newer downloaded addon survives client restarts.

To publish a client update, run
`make prepare-release VERSION=<major.minor.patch>` with a higher version. It
turns the files under [changes/](changes/README.md) into a section of
[CHANGELOG.md](CHANGELOG.md), deletes them, and writes the version to
`package.json`, `package-lock.json`, the Cargo package manifests and
`Cargo.lock`, `desktop/src-tauri/tauri.conf.json`, the addon TOC and the
website's title bar. Commit that, open the pull request with the `release`
label, merge it to main, then run `make release` as
[releasing](docs/releasing.md) describes. The client only installs a release
with a higher version than its own, so a release under the same version
reaches only new installs. `make build` builds with the version as it stands
and publishes nothing. Release build builds signed macOS Apple Silicon,
Windows x64, Ubuntu deb, and Fedora rpm packages and the signed addon update.
Release promote publishes that complete feed at the Goldbook site. The
individual build workflows still produce standalone installers. Merging to
main publishes nothing.

The website's **Download** page offers the client installers from
`updates/latest.json` on the same server. It selects the visitor's system,
with buttons to switch to another one, and links the public addon repository
for installing the addon by hand. A server without a published feed says it
has no downloads. The macOS download is the updater's `Goldbook.app.tar.gz`
for Apple silicon, because the feed carries no `.dmg`.

The update signing key is the GitHub Actions secret `TAURI_SIGNING_PRIVATE_KEY`.
Keep its private backup safe; the client's pinned public key verifies every
package. The repository can remain private because clients download the signed
files from `/goldbook/updates/`. Publication uses the restricted deployment SSH
helper and retains previous immutable client packages. Updating that helper
requires copying `scripts/deploy-ovh.py` to `/opt/goldbook/deploy-ovh.py` on OVH.
