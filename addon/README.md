# Goldbook

A World of Warcraft addon that scans the auction house, shows prices in item
tooltips and a searchable window, finds deals, advises what to sell, and keeps
a ledger of your gold and trades.

With the Goldbook app, the addon syncs with the
[Goldbook website](https://app.jkc-be.com/goldbook/): a price history for
every item, and your characters' gold, bags, bank and trades. Get the app from
the website's [Download](https://app.jkc-be.com/goldbook/#download) page.

This addon-only repository is a generated mirror of
[`jkc-be/goldbook/addon`](https://github.com/jkc-be/goldbook/tree/main/addon).
The public upstream also contains the desktop app, server, and web UI. Make
changes in the upstream repository; an approved mirror update replaces this
copy. `upstream.json` records the exact source commit.

## Requirements

World of Warcraft with the modern auction house API (`C_AuctionHouse`). The
addon declares interface 16001, the 1.60 "Forever" client. On another client
version the game lists it as out of date.

## Install

The easiest way is the Goldbook app from the
[Download](https://app.jkc-be.com/goldbook/#download) page. It installs the
addon, keeps it up to date, and syncs it with the website.

Download the attached `Goldbook-<version>.zip` from
[Releases](https://github.com/jkc-be/goldbook-addon/releases/latest). Use that
same ZIP for manual installs. It contains `Goldbook/Goldbook.toc`
directly. The automatic **Source code (zip)** download wraps the files in
`goldbook-addon-<tag>` and is not an installable addon package.

To install the addon by hand:

1. Quit the game. The game only looks for new addons when it starts.
2. Extract the release ZIP and copy its `Goldbook` folder into `Interface/AddOns` of your game flavor, for
   example `World of Warcraft/_classic_/Interface/AddOns/Goldbook`. The folder
   must contain `Goldbook.toc` directly.
3. Start the game.

When you log in, chat says `Goldbook loaded. Type /gb for commands.` and a gold
coin button sits on the edge of the minimap.

## Sync with the website

The addon works on its own, but an addon cannot open network connections. It
queues each scan, and each character's gold, bags and bank, in its
`SavedVariables` file, which the game writes on `/reload` and on logout. The
Goldbook app watches that file and uploads it to the
[Goldbook website](https://app.jkc-be.com/goldbook/).

1. Install the app from the [Download](https://app.jkc-be.com/goldbook/#download)
   page and leave it running.
2. Scan in the auction house, then type `/reload`. The app uploads the scan a
   few seconds later.
3. On the website, **Prices** shows the price history of every item. To see
   your characters, type `/gb web` in game and log in under **Characters** with
   the ID and key it shows.

The app uploads only a hash of the key. Anyone with the ID and the key sees
the gold, bags and bank of your characters, so keep the key to yourself. The
address `/gb web` shows is `X-Website` in `Goldbook.toc`.

## Share order books and compare prices

With version 0.1.12 or later, run `/gb scan full` at the auction house to
record buyout prices, quantities and available seller names for each resolved
item. Keep the desktop app running and type `/reload` or log out to upload
the books. A complete item search also records its book. `/gb status` shows
how many snapshots are saved locally.

On the website, select an item in **Prices** to see its price ladder,
cumulative sell-side depth and earlier observations. Use **Compare** beside
Copper Ore and Copper Bar, for example, to plot both price histories together.
Old price summaries cannot supply an order book; collect a new full scan.
These are recorded sell listings, not a live feed or standing buy orders.

## Use

| Action | Result |
|---|---|
| Left click **Goldbook scan**, or `/gb scan` | Quick scan: lowest price and quantity per item |
| Right click **Goldbook scan**, or `/gb scan full` | Full scan: every auction, adds market values and order books |
| `/gb deals` | What is listed right now below its resale or vendor value |
| `/gb sell` | Your bags: what to auction, at what price, and what to vendor instead |
| `/gb movers` | The prices that rose most since the day before; **Fallers** lists those that fell |
| `/gb gold` | Gold per character, gains, net worth, a chart over a week, a month or two months, and this month's trades |
| `/gb trades` | Your auction house sales and purchases and your sales to vendors, with their totals |
| Alt+click an item, or `/gb item <link or name>` | The item's price history. **Back to Prices** returns to the list it was opened from |
| `/gb show [text]`, or left click the minimap button | Price list, filtered by item name |
| `/gb autoscan` | A quick scan each time the auction house opens, at most every 15 minutes |
| `/gb minprofit <gold>` | The profit a resale deal must make |
| `/gb status` | The addon's version, items priced and scans waiting for sync |
| `/gb web` | The website's address, and the ID and key that log you in to its character pages |
| `/gb minimap` | Hides or shows the minimap button |
| `/gb theme dark`, `/gb theme light`, or the half-filled ring by the window's close button | Draws the window in dark ink, the default, or on light parchment |
| `/gb scale <0.7-1.4>`, or the slider in Options > AddOns > Goldbook | Sizes the window, apart from the game's UI scale. 1 is its normal size |

## Build a release ZIP

```sh
python3 package.py dist
```

The packaging command checks that the TOC's files are present and produces
`dist/Goldbook-<version>.zip`. The release workflow tests and packages each
mirror update. Existing release assets are immutable; change the version in
`Goldbook.toc` upstream before publishing different addon code.

## Publish to CurseForge

After a mirror update, **Package addon release** tests the addon and publishes
the installable ZIP to GitHub. Approve its `curseforge` job to upload that exact
ZIP to [Goldbook on CurseForge](https://www.curseforge.com/wow/addons/goldbook),
project `1747971`. The upload uses the
[CurseForge Upload API](https://support.curseforge.com/support/solutions/articles/9000197321-curseforge-api).
The game version comes from `Goldbook.toc`; versions containing `alpha` or
`beta` use the corresponding release type.

The `CURSEFORGE_API_TOKEN` secret belongs in the protected `curseforge`
environment, which accepts only `main` and requires approval by `jkc-be`.
Keep repository-level secrets empty. The token is passed only to the upload
step, in an HTTP header. The uploader does not print response bodies or
network error details, and does not forward credentials through redirects.

A successful upload adds `curseforge.json` to the GitHub release. It contains
the public CurseForge file ID and the ZIP's SHA-256 hash. Later mirror updates
skip an upload already recorded for the same ZIP. If the upload fails without
a receipt, check the CurseForge files before retrying, since a lost response
or a failed receipt upload can leave the file published. CurseForge may still
need to approve a submitted file before it becomes public.

The `.pkgmeta` file also describes the folder layout for CurseForge's
[native packager](https://support.curseforge.com/support/solutions/articles/9000197281-automatic-packaging).
It puts `Goldbook.toc` directly in `Goldbook/` and excludes development files.
The workflow uploads the existing tested ZIP, so no packaging webhook is
needed. Enabling both publishing methods can produce duplicate uploads.

## Test

The tests run the addon against a simulated client with
[LuaJIT](https://luajit.org):

```sh
luajit tests/run.lua
luajit tests/scanner.lua
luajit tests/sellers.lua
luajit tests/orderbook.lua
luajit tests/professions.lua
luajit tests/trades.lua
python3 -m unittest discover -s tests -p 'test_*.py'
```

## License

Copyright (c) 2026 jkc-be. All rights reserved. See [LICENSE](LICENSE).
