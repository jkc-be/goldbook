# Changelog

The changes in each Goldbook version, newest first. The desktop app and the
addon share one version, set with `make version`. The server and the website
have no version of their own; their changes are listed under the version they
were released with.

## Unreleased

### Addon

- Vendor prices come from the sell price the game's tooltip shows, for every
  item, so they are right before you sell one. They no longer come from the
  game's item data or the merchant's buyback list, and `/gb deals` no longer
  marks vendor deals as `Vendor?`. Vendor prices saved before are read again
  the next time an item is scanned or in your bags.

## 0.2.1 - 2026-10-17

- Build the desktop app and server with Rust 1.99.1 and align their shared
  crate versions. All Rust crates now use edition 2024, with the same pinned
  toolchain for local builds, CI and the server image.

## 0.2.0 - 2026-10-17

### Addon

- Restyle the Goldbook window in the Ledger design, dark by default. A
  light/dark button left of the close button switches it to parchment, as do
  `/gb theme` and the Options tick. Views move to a side rail, with the last
  scan, scans waiting to sync and Reload at its foot.
- Tune both palettes for how the game draws them: a client with raised
  brightness turned light panels, rules and edges white. Words are set in
  Friz Quadrata and figures in a larger Arial Narrow.
- Size the window with `/gb scale <0.7-1.4>` or the Options slider, apart
  from the game's UI scale.
- Show a 7-day price line on Prices, Deals, Sell and Movers.
- Draw the item chart as the website does: lowest buyout over an area,
  market value, the amount listed as bars, a legend, the latest values and a
  tooltip per point, over 1D, 1W, 1M or 2M. Back returns to the list the item
  came from.
- Keep the last week of prices by the hour, and chart them. A day's and an
  hour's price is its lowest, as on the website.
- Take the newer prices, days and hours the app downloads from the server
  when the addon loads. Tooltips and the item view say "from the server".
- Gold shows cards for total, today, 30 days and net worth, a 1W/1M/2M chart,
  and this month's trades. Trades shows totals and filters by kind and
  character. Movers switches between risers and fallers.
- Show money with thousands separators, such as 1,763g 50s 00c.

### Desktop app

- Lay the app out like the website, light by default, with one side rail and
  a Light/Dark switch that the website inside the app follows.
- Download the server's prices and history for your realms after a sync, at
  most every 15 minutes, into `ServerData.lua` in the addon folder. Type
  /reload in game to load them.
- Bring the window back from the tray, the Dock or a second launch after
  Prices or Characters was shown.

### Website and server

- Restyle the site in the Ledger design: a light parchment theme by default
  and a dark ledger theme chosen with the Light/Dark switch in the side rail.
  The browser remembers the choice.
- Show the account's total gold in the top bar and the sign-in state with
  Log in or Log out in the rail on every page.
- Show the roster above a character's page, with that character marked, and
  the trade totals as one strip.
- Show each item's 7-day line and change as one column over the same week.
- Make the order-book depth chart interactive: each level's units,
  cumulative units and cost to buy up to it, linked to the price ladder, for
  any saved snapshot. Seller names are no longer shown.
- Add `GET /api/export`, a realm's prices with hourly and daily history,
  gzip-compressed when the client asks.

## 0.1.13 - 2026-10-16

- Upload seller snapshots in batches of up to 100 instead of one request per
  item. Each batch uses one database transaction and one local state write.
- Remember 50,000 upload identities instead of 500, preventing full-scan
  seller queues from being uploaded again on every sync.

## 0.1.12 - 2026-10-16

### Website

- Compare up to six items on one minimum-buyout history graph, with a table
  of their latest observations. The original page layout is preserved.
- View best ask, price-level quantities and cumulative sell-side depth in
  the order-book panel. Missing books explain how to collect and upload data.

### Addon and app

- Full auction-house scans now record order books for resolved items,
  including unknown sellers. Reload or log out with the desktop app running
  to upload the snapshots.
- Completed scans record empty books for previously seen items that have
  disappeared. Incomplete item books are excluded.
- Retain up to 10,000 book snapshots, subject to the existing 200,000-offer
  and 14-day limits. Scan completion and `/gb status` report saved books.

## 0.1.11 - 2026-10-16

### App

- Sign in with Battle.net from Settings to connect upload access to a verified
  player identity. Complete sign-in in the browser using the code shown by
  Goldbook. The app saves its own enrollment session and upload credentials.

### Server

- Optional Battle.net OAuth requires sign-in for self-service upload setup.
  Player blocks cover linked WoW fingerprints and replacement-token requests.
  Linking an existing anonymous fingerprint revokes its old upload tokens.
- `scripts/upload-access.py --identity-type battlenet` lists, blocks, and
  unblocks verified player hashes. Character-page login stays separate.
### Website

- View the order book for an item, with known sellers, units, cumulative units,
  and unit buyout at each price level.
- Select an earlier observation to review its order book and seller shares.
  Previously uploaded seller snapshots are included in the history.

### Addon

- Retain successive completed auction searches until they can sync, instead
  of replacing an item's earlier observation. Local history is limited to
  500 observations, 200,000 offer rows, and 14 days. Uploaded observations
  remain on the server.

## 0.1.10 - 2026-10-16

### App

- The app sets up upload access automatically when you save your game folder.
  Users no longer need an administrator to supply a token on servers that
  enable automatic setup.
- Existing installations using `dev-token` on the official server register
  automatically after updating. Custom tokens are preserved.
- If setup fails while offline, the app retries and **Sync now** can retry
  immediately.
- Each WoW account gets its own upload credential. New account folders are
  detected automatically, including after the first game login.

### Server

- Optional self-service registration binds tokens to a hash of the WoW
  account-folder identifier. Blocking a fingerprint rejects its existing
  tokens and replacement requests while other accounts can keep uploading.
  The server stores token hashes and limits registration attempts. Enable
  it with `SELF_REGISTRATION=true` before releasing the app.
- `scripts/upload-access.py` lists, blocks, and unblocks account fingerprints.

## 0.1.9 - 2026-10-16

### App

- Fresh installs ask for a server-issued upload token instead of prefilling
  `dev-token`, which the production server rejects.
- When the server refuses a token, the app explains how to replace it in
  Settings. Existing installations need to replace any saved invalid token.

## 0.1.8 - 2026-10-16

### Addon

- Vendor prices come from what a vendor really paid, read from the merchant's
  buyback list and from vendor sales already booked. The game's item data is
  wrong for some items, such as Rough Bronze Leggings. `/gb deals` marks a
  vendor deal whose price was not seen paid yet as `Vendor?`.
- Goods merchants sell in any amount, such as coal, flint and tinder, thread
  and vials, are no longer resale deals, and `/gb sell`, the bags and net
  worth value them at what a vendor pays instead of their auction price.
  Goldbook knows the common ones and learns the rest at every merchant you
  open. Tooltips show what a merchant asks for them.

## 0.1.7 - 2026-10-16

### Addon

- The addon's source code is public at
  [jkc-be/goldbook-addon](https://github.com/jkc-be/goldbook-addon), with a
  README on installing it and syncing it with the website.
- `/gb web` shows `https://app.jkc-be.com/goldbook` as the website's address.

### Website

- A **Download** page offers the app for your system, with buttons to switch
  to another one, and links the addon on GitHub for installing it by hand.

## 0.1.6 - 2026-10-16

### Website

- **Link another computer** under **Characters** joins the web logins of two
  computers. Either login then shows the characters and trades of both. A
  character played on both shows once.

## 0.1.5 - 2026-10-15

### Addon

- `/gb trades` lists your auction house sales and purchases, read from the
  invoices in your mailbox, with the 5% cut, the net and the profit or loss.
- Sales to a vendor are booked from the merchant's buyback list, and taken off
  again when you buy the item back.
- The window, the options, the minimap tooltip, `/gb status` and the login
  message show the addon's version.

### Website

- **Characters** and each character page show the trades: sales, purchases,
  the cut, the net, a summary by item and the full history.

## 0.1.4 - 2026-10-15

### App

- On Linux, the **Prices** and **Characters** tabs no longer squeeze the
  website beside the settings page.
- Clearer messages when an update fails.

## 0.1.3 - 2026-10-15

### App

- The app downloads signed updates of itself in the background and offers to
  install them.
- The app installs signed addon updates in your game folder. Type `/reload`
  afterwards.
- **Prices** and **Characters** tabs show the website inside the app.
  **Characters** signs in with the login the game saved.
- **Sync automatically**, on by default, uploads after each game file write
  and checks again every 15 minutes.
- The app looks like the website.
- The macOS app is ad-hoc signed, so macOS no longer reports the download as
  damaged.
- On Linux with Wayland, the app no longer quits with a protocol error
  (Error 71) on some graphics drivers.

### Addon

- Saves complete auction house searches, also from Auctionator, with each
  seller's listings.
- **Profession**, **Item type** and **Quality** filters on the Prices, Deals,
  Sell and Movers lists.

### Website

- A **Sellers** panel per item: each seller's quantity, share of the stock and
  price range.
- **Profession**, **Item type** and **Quality** filters above the price list.
- Item links go to Wowhead's Forever database.
- The website also works under a path, as at
  `https://app.jkc-be.com/goldbook/`.

## 0.1.2 - 2026-10-15

### App

- The app is rebuilt with Tauri and Rust, in place of Electron. It keeps the
  settings and upload history of the earlier version.

### Server

- The server is rebuilt in Rust. It keeps the same database, routes and
  upload format, and existing databases upgrade in place.
- A character keeps its realm, and two snapshots of the same logout count
  once.

## 0.1.1 - 2026-10-15

### App

- **Open website** signs you in to the character pages with the login the
  game saved, without putting the key in a URL.

## 0.1.0 - 2026-10-15

The first version with the desktop app.

### Addon

- Quick and full auction house scans, with prices in item tooltips and a
  searchable price list.
- `/gb deals`, `/gb sell`, `/gb movers` and `/gb gold`: deals below resale or
  vendor value, what to sell and at what price, the biggest price changes, and
  your gold per character with a 30 day chart.
- Each item's daily prices for 60 days, shown on Alt+click or `/gb item`.
- A web login, shown with `/gb web`, and each character's bags and bank saved
  at logout.
- Gold kept per hour.

### App

- Installs the addon and uploads your scans and characters from
  `SavedVariables`.

### Website

- Prices per realm with market values, 14 day trends and each item's price
  history.
- **Characters**: each character's gold over a day, 7 days or 30 days, and
  what its bags and bank would bring.

### Server

- A self-hosted server with upload tokens, login limits and an optional
  public address through Traefik.
