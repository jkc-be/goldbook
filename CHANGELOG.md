# Changelog

The changes in each Goldbook version, newest first. The desktop app and the
addon share one version. The server and the website have no version of their
own; their changes are listed under the version they were released with.

Changes not yet released live as files in [changes/](changes/README.md). The
release pull request runs `make prepare-release VERSION=x.y.z`, which adds
them here as a new version and sets that version everywhere.

## 0.4.1 - 2026-10-30

### Addon

- Add an auction house panel in Goldbook's dark and light themes. Open it
  with the **Goldbook** button at the auction house or `/gb ah` to search,
  buy, post bag items and cancel your auctions. Each trade has a review step.
  Resize it from the bottom-right corner; Goldbook remembers the size.
- Command+click a bag item on macOS, or Ctrl+click on Windows, to open its
  live listings. Item icons also appear in the order book.
- Hide Blizzard's auction window by default while the Goldbook panel is
  open. Use Goldbook settings to keep it visible. Closing Goldbook's auction
  panel closes Blizzard's window and ends the auction session too.
- Browse saved scan prices immediately. Show the last scan time and a Quick
  scan reminder; fetch current listings only when opening an item.
- Run quick and full scans from the auction panel and browse Deals using
  the same calculations as Market. Filter by profession, item type and
  quality, or use Classic auction categories with nested submenus. Group item
  variants with the stack icon, then expand a group to choose the exact
  suffix or item level.
- Save item groups with minimum, normal and maximum prices, undercut
  amounts, post caps, stack sizes, durations and shopping limits. Posting,
  undercut and shopping scans build a queue from current listings. Confirm
  each post or cancellation, or open a shopping result to review a purchase.
  Groups and rules are available inside Automation. Posting durations are
  2, 8 or 24 hours.
- Each GitHub release of the addon now carries a `release.json`, so WowUp
  picks the right Goldbook download for the Forever client when it installs
  or updates the addon from GitHub.

### Server

- Uploading now always needs Battle.net sign-in in the app. The server no
  longer takes the shared `UPLOAD_TOKEN` or registers upload tokens without a
  Battle.net session, and ignores `UPLOAD_TOKEN` and `SELF_REGISTRATION` in
  its environment. A token registered before Battle.net sign-in stops
  uploading; click **Sign in with Battle.net** in the app to get a new one.

### Build

- Sign and notarize the macOS app and disk image so Gatekeeper can verify
  Goldbook downloads with Apple.
- Add detailed help for every Makefile command, with arguments, examples,
  prerequisites and effects. Use `make help release`, `make help-release`
  or `make release HELP=1`. Help mode skips commands and their prerequisites,
  including when several commands are requested together.
- Explain that `make release --help` displays Make's own help, and point
  missing-version errors to the relevant command help.
- Add WoWInterface as a secondary addon download destination. Its separate
  publishing workflow follows CurseForge and cannot block a release.

## 0.4.0 - 2026-10-19

### Addon

- The website keeps showing a character's bags after you quit the game.
  Quitting used to upload them empty, because the game empties the bags
  before the addon saves; only `/reload` kept them.
- Looted gold and other small amounts from an hour that has ended now reach
  the website when you log out. They used to wait for your next login. The
  hour you log out in still waits, as it may yet add up more.

### Desktop app

- Settings no longer has an **Upload token** field. The app sets up its own
  upload token for each WoW account, on Goldbook's server after **Sign in
  with Battle.net**. A token entered by hand in an earlier version is
  dropped.

## 0.3.0 - 2026-10-19

### Addon

- In the dark theme, losses, warnings and rare, epic and legendary names are
  a little lighter, so they stay readable on a selected row.
- The light theme (`/gb theme light`) draws the window on a soft, modern
  parchment with dark brown ink and a muted amber accent, in place of the
  white and lemon yellow it showed in game.
- The Prices title says how many items have been scanned on the realm, as
  the website now does.
- The quality filter offers Poor to Epic only. Legendaries are bound and
  can't be listed, and Classic has no artifacts or heirlooms.
- **Market** shows a rising price chart and **Inventory** a chest in the rail.
- With a filter chosen on Ledger › By item, **Clear filters** no longer runs
  past the window's edge; the search box narrows to make room.

### Desktop app

- After **Sign in with Battle.net**, the app sends each account once more,
  even when nothing changed in game, so the website's **Sign in with
  Battle.net** shows it right away.
- In the dark theme, losses, warnings and rare, epic and legendary names are
  a little lighter, so they stay readable on a selected row.
- The light theme is a soft, modern parchment with dark brown ink and a muted
  amber accent, in place of white and lemon yellow, and matches the addon.
- **Market** shows a rising price chart and **Inventory** a chest in the rail.
- **Settings** replaces **Sync** in the rail, with the settings always open,
  and **Log in** at the bottom of the rail signs in with Battle.net. Signed
  in, Inventory, Ledger and **Open website** show your Battle.net player's
  characters without asking for a game account, and **Log out** ends it.
- **Settings** has a **General** and an **Advanced** tab. The server and the
  optional upload token move to **Advanced**, with **Use the default server**.
  A sync icon beside the theme switch at the foot of the rail syncs from any
  view, as **Sync now** in Auction scans does, and Auction scans and Updates
  sit side by side at one height.

### Website

- Sign in on the website with **Sign in with Battle.net**, below the ID and
  key. It shows the characters and trades of every computer whose Goldbook
  app you signed in with Battle.net, and of the IDs linked with them, without
  a key or **Link another computer**. The ID and key login works as before.
- Character names on Gold are in the normal text colour, with a bar in the
  class's game colour before each, so every class reads clearly in both
  themes, also on a hovered or selected row.
- Item names in Inventory, Ledger's Accounting entries and By item, and
  Gold's best sale open the item's prices in a pane beside the page, on the
  realm it was seen on, as the addon does. **×** or Esc closes it. The app's
  views do the same. Item names in Inventory and Accounting have their
  rarity colour back.
- The light theme is a soft, modern parchment with dark brown ink and a muted
  amber accent, in place of white and lemon yellow, and matches the addon.
- On a server with Battle.net sign-in, the login puts **Sign in with
  Battle.net** first and folds the ID and key away under **Log in with an ID
  and key instead**.
- Prices lists every item scanned on the realm, each at its newest price,
  as the addon does, instead of only the items in the newest scan. The
  title counts them all, and **Seen** shows when each item was last scanned.
- The quality filter offers Poor to Epic only. Legendaries are bound and
  can't be listed, and Classic has no artifacts or heirlooms.
- **Market** shows a rising price chart and **Inventory** a chest in the rail.
- Drag the border between a list and an item's prices to make either wider,
  in Market's Prices and in the item pane beside other views. The arrow keys
  move a focused border too, and a double click restores the default width.
  The browser keeps the width you chose.

### Server

- **Sign in with Battle.net** in the app gets past the page where you enter
  the app's code. That page stopped with "sign-in confirmation must come
  from this Goldbook server" in every browser.
- The pages of the app's **Sign in with Battle.net** wear the website's look
  and theme: a large field for the app's code, which may be typed in
  lowercase, and a clear page with the next step when sign-in fails.
- `/api/prices` lists the newest price of every item scanned on a realm and
  faction, with each item's scan time, and counts them all. An upgrade fills
  this from the scans already stored.
- The server no longer risks hanging under parallel requests: it bundles
  SQLite 3.53.2, which includes the fix for a deadlock in 3.51.1 between a
  connection closing and others opening.

## 0.2.5 - 2026-10-18

### Addon

- The **Profession** filter offers Herbalism, which shows the herbs you
  gather. Those that alchemists and other professions use, such as
  Peacebloom, still show under those professions too.
- The **Profession** filter offers Skinning, which shows the leathers, hides
  and scales you skin. Those that leatherworkers use, such as Light Leather,
  still show under Leatherworking too.

### Website

- The **Profession** filter offers Herbalism, which shows the herbs you
  gather. Those that alchemists and other professions use, such as
  Peacebloom, still show under those professions too.
- The **Profession** filter offers Skinning, which shows the leathers, hides
  and scales you skin. Those that leatherworkers use, such as Light Leather,
  still show under Leatherworking too.

## 0.2.4 - 2026-10-17

### Addon

- The window's rail has three hubs instead of seven views, each with tabs
  across the top of the page: **Market** (Prices, Deals, Movers),
  **Inventory** (Bags, Mail) and **Ledger** (Gold, Accounting, By item). A hub opens
  the tab it showed last. Every command still opens its own tab, the mailbox
  still opens Mail, and the mail count sits by Inventory. An item's history
  keeps the hub it was opened from. Lists show 17 rows instead of 19.
- Sell becomes Bags (`/gb bags`; `/gb sell` still opens it).
- Add a By item tab under Ledger (`/gb items`): the accounting per item, with
  units bought and sold, the average cost and sale, the realized profit or
  loss and when the item last moved, a search box, and profession, item,
  quality and character filters.
- Shift+click an item at the auction house to open its price history in
  Goldbook, as Midas does: in the auction house's lists, your bags and addons
  such as Auctionator, but not while writing in chat. An Options tick turns it
  off.
- The Options panel scrolls, so the web login at its bottom is always within
  reach. It now says what the desktop app and the website add: the app syncs
  both ways, uploading your scans and bringing back the prices others scanned
  on your realm.
- The minimap button and the window's title bar show Goldbook's crest, the
  gold coin of the website, drawn by the addon itself.
- Vendor prices come from the sell price the game's tooltip shows, for every
  item, so they are right before you sell one. They no longer come from the
  game's item data or the merchant's buyback list, and `/gb deals` no longer
  marks vendor deals as `Vendor?`. Vendor prices saved before are read again
  the next time an item is scanned or in your bags.
- Add a Mail view, beside Bags under Inventory, that opens with the mailbox. It
  lists every mail with its items, a Sold, Bought, Cancelled, Expired or Other
  tag, the sender, the days left and its gold or COD, with segments, search
  and sorting. **Collect N mails** takes the mails shown one at a time, skips
  COD mail, and stops when the bags fill, the mailbox closes or you click
  **Stop**. `/gb mail` opens it; an Options tick keeps it from opening by
  itself.
- Trades becomes Accounting (`/gb accounting`; `/gb trades` still opens it):
  every gold movement as revenue or expense, by source. Besides auction and
  vendor sales and auction purchases it books merchant purchases, trades
  with players (each item given or got, the gold shared by market value, and
  the player's name), mail gold in and out, cash on delivery, quest rewards,
  looted gold, repairs, postage, auction deposits, flights, training and
  talent resets. Gold nothing explains is other income or expense. Looted
  and other gold are added up per hour.
- The Accounting view has All, Revenue and Expenses, a source chip beside the
  character chip, and Revenue, Expenses, Net and Realized profit cards. The
  realized profit counts goods bought and sold by any means. The Gold view's
  side panel shows the same totals for the month.
- Keep 3,000 entries per character instead of 1,000, and never drop one the
  mailbox may still show.

### Desktop app

- The app icon is Goldbook's crest, the gold coin of the website.
- The rail has the addon's hubs: **Market**, **Inventory** and **Ledger**
  open the website's Prices, Bags and Gold inside the app, whose tabs reach
  the rest, then **Sync**. Inventory and Ledger sign in with the login the
  game saved and open on their own tab. Characters is gone.
- The app opens in the dark theme unless you chose the light one.
- A development build (`make run`) always installs the addon of its checkout,
  and no longer installs a published addon update over it.
- `make build` also installs this checkout's addon into the World of Warcraft
  folder; `make install-addon` does only that.
- `make run` starts the local server stack first, rebuilt from this checkout
  when it changed, so the development app uploads to a matching server.

### Server

- Accept and keep every kind of accounting entry the addon books: merchant
  purchases, player trades, cash on delivery, gold mailed, quest rewards,
  looted gold, repairs, postage, auction deposits, flights, training, talent
  resets and other income and expenses. An item in a player trade may book
  for 0. Migration `0012_accounting.sql` rebuilds the trades table with the
  same rows.
- Keep the other player of a trade or mail as `party`, and return it from
  `/api/trades`. Deploy the server before the app: an older server refuses an
  account upload with the new entries.
- Add `/api/deals` and `/api/movers`. They apply the addon's deal and mover
  rules to the realm's newest scan and the lowest price of each day in the
  last 60, with the same search and filters as `/api/prices`.
- `/api/desktop-login` opens the website's view named by `?view=`, such as
  `bags`. Without one it opens `#characters` as before, which the website
  now sends on to Gold.

### Website

- Rename the Trades section Accounting. It totals revenue, expenses, the net
  and the profit realized on goods, and filters the history to all, revenue
  or expenses. Each entry names its source, such as "Trade sale to Mirelle"
  or "Mail gold in from Mirelle".
- The website has the addon's navigation: **Market**, **Inventory** and
  **Ledger** in the rail, with **Download** under Account. Each hub has tabs
  at the top of the page: Market has Prices, Deals and Movers, Inventory has
  Bags, and Ledger has Gold, Accounting and By item. Every tab has its own
  address, such as `#deals`, so links, back and forward work. Mail stays in
  game.
- Add **Deals**: what the newest scan lists at 70% or less of its resale
  price, found as the addon finds resale deals, with the profit per unit
  after the cut. Vendor deals stay in game, because the server has no vendor
  prices.
- Add **Movers**: the prices that rose or fell since the day before, as the
  addon's Movers view has them.
- Add **Bags**: the bags and banks of all the account's characters in one
  list, with a character filter.
- Add **Gold**: the account's gold over time, all characters summed or one
  of them, and a row per character. A character's name picks it in the
  character chip, here and in Accounting. The account's ID and **Link another
  computer** are under the characters.
- Remove **Characters**: Gold, Bags and Accounting show everything it did.
  `#characters` opens Gold, and an old `#character/<name>-<realm>` or
  `#characters/<name>-<realm>` link opens Gold with that character chosen.
- The account's Accounting moves to Ledger.
- Add **By item** (`#items`): each item bought or sold with the units, the
  average cost and sale, the profit realized on the units both bought and
  sold, and when it last moved, with Bought, Sold, Realized profit and Best
  item cards, a search and the profession, item, quality and character
  chips. It replaces the By item panel under Accounting.
- The website opens in the dark theme unless you chose the light one.
- The website and the desktop app's own pages look like the addon's window, in
  its palettes as the game shows them, with its fonts, title bar, theme
  button, tables, filters and status lines; Bags, Gold and Accounting now
  have the addon's columns, cards and panels.
- A tab no longer opens scrolled down to a table that shared its name.

## 0.2.3 - 2026-10-17

### Addon

- Fix a Lua error whenever a merchant opened, on clients that read merchant
  items with `C_MerchantFrame.GetItemInfo` instead of `GetMerchantItemInfo`.
  Goldbook now learns the goods merchants sell on those clients.

## 0.2.2 - 2026-10-17

### Desktop app

- Require HTTPS for remote uploads, sign-in, and server price downloads.
  HTTP remains available for loopback servers and bypasses environment proxies.
- Refuse API redirects so credentials and account data stay with the configured
  server.
- Check manual upload credentials before saving settings or starting sync.
- Backport the upstream GLib iterator security fix for Linux builds. Replace
  the backport with an upstream release when Tauri's dependency chain supports it.

### Addon

- Remove the misleading "Nothing waiting to sync" and "N scans waiting to sync"
  label from the side rail.

### Build

- Pin Linux CI, installer, release, and deployment jobs to Ubuntu 24.04.

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
