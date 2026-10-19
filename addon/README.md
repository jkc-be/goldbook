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
| `/gb ah`, or **Goldbook** above the auction house | Search, buy, sell, manage your auctions and run rule-based scans |
| Command+click a bag item on macOS, or Ctrl+click on Windows | Open its live listings in Goldbook while at the auction house |
| Left click **Goldbook scan**, or `/gb scan` | Quick scan: lowest price and quantity per item |
| Right click **Goldbook scan**, or `/gb scan full` | Full scan: every auction, adds market values and order books |
| `/gb deals` | What is listed right now below its resale or vendor value |
| `/gb bags` | Your bags: what to auction, at what price, and what to vendor instead. `/gb sell` opens it too |
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

## Auction house panel

Open the auction house and click **Goldbook** above it, beside **Goldbook
scan**, or type `/gb ah`. The panel uses the same dark/light theme and scale
as the rest of Goldbook. Drag its bottom-right corner to resize it; Goldbook
remembers the size. Closing the auction house closes the panel and clears
its live results. Closing the Goldbook panel also closes Blizzard's auction
window and ends the auction session.

Command+click a bag item on macOS, or Ctrl+click on Windows, to open that
item's live listings. This preserves the item's variant and works while
Blizzard's window is hidden. Finish any scan or trade review before using
the shortcut.

Blizzard's auction window is hidden by default while the Goldbook panel is
open. Clear the checkbox in Options > AddOns > Goldbook to keep it visible.
Your choice is saved. Theme changes follow the rest of Goldbook; this panel
has no separate theme button.

**Quick scan** updates lowest prices. **Full scan** also records market
values and order books, with the same 15-minute cooldown as `/gb scan full`.
The buttons show scan progress in the footer and are unavailable during
another scan or trade review. Closing the auction session stops a scan.

The filters match Market: profession, materials/recipes/crafted items, and
quality. They apply to scan prices, Deals, Sell and My auctions. The category
menu uses Classic's auction categories and submenus, including armor slots;
it combines with the other filters. The stack icon groups
variants of the same item, such as Battle Knife suffixes, into one row with
their total quantity and lowest price. Click the group to choose the exact
variant, or click the stack icon again to show all variants separately.

- **Browse** searches saved scan prices immediately, without waiting for
  auction queries. The panel shows the last scan time; run at least a
  **Quick scan** for a fresh reference. Each item's tooltip shows when its
  price was observed. Opening an item resolves its exact variant and loads
  current listings. If several item levels match, choose one first. A cached
  price never authorizes a purchase. Select a live listing and review it. Commodities get a current total for the quantity you
  enter, across the cheapest listings. That quote expires after ten seconds.
  Other items buy the entire selected listing. Bid-only auctions are omitted.
- **Deals** uses Market's deal calculations and minimum-profit setting.
  Select a deal to see its estimated return, then **Find live listings** to
  check current prices before buying. A completed scan refreshes the view.
- **Sell** lists auctionable bag stacks. Select one and enter a quantity, a
  unit price in gold and a duration. The initial price, when present, is
  Goldbook's last recorded minimum. Review the total and deposit before
  posting. A post uses at most the selected bag stack. Ordinary items are
  posted one at a time; commodity posts use the quantity you enter.
- **My auctions** lists your auctions and lets you review a cancellation.
  The review shows the cancellation fee. Cancelling also loses the deposit;
  returned items arrive by mail.
- **Automation** runs posting, undercut and shopping scans for your saved
  groups. It reads all pages of each item's listings before building its
  action queue. Scans never buy, post or cancel on their own. Select a queued
  action and confirm it; shopping results open current listings for review.

Under **Automation > Groups and rules**, name a group and enter its item IDs, separated by
commas. Opening the editor with an item selected fills in its ID. Each item
belongs to one group; its variants use that group's rule. **Load next group**
cycles through saved groups. Saving replaces the group with that name.

| Setting | Meaning |
| --- | --- |
| Minimum / normal / maximum | Lowest allowed unit price, fallback price and upper price bound |
| Below minimum | Skip the item, use the minimum, or use the normal price |
| Above maximum | Use the normal price or the maximum |
| Undercut | Copper to subtract from the cheapest competing unit price; zero matches it |
| Post cap | Maximum number of your items listed for that exact item variant; existing auctions count |
| Items per auction | Maximum commodity quantity in each queued post, within the selected bag stack; ordinary items post one at a time |
| Duration | 2, 8 or 24 hours |
| Shopping limit | Highest unit price to include in shopping scan results |

Price fields accept a gold amount such as `12.50`, coin amounts such as
`12g 50s`, or a percentage such as `120% market`. Supported sources are
`market`, Goldbook's recorded market value or usual price; `vendor`, its
recorded vendor price; and `minbuyout`, the lowest unit buyout in the current
search. A missing source skips the item. These are Goldbook expressions;
TSM custom strings and operation imports are not supported.

A posting scan counts your existing auctions, skips prices outside the rule
as configured and divides eligible bag stacks into posts under the cap. An
undercut scan queues cancellable auctions with cheaper competing listings.
A shopping scan searches the base item IDs in the groups; use **Browse** for
a specific suffix, item level or battle pet variant.

The queue expires after five minutes or when the auction session changes.
Requests from Blizzard's window or another auction addon invalidate the
selection and stop an active rule scan. Finish the current scan or panel
request before starting another. **Stop scan** discards an unfinished queue. Each action
requires a click, including the game's own posting warning when applicable.
If the server does not acknowledge a transaction, the panel asks you to
check your mail and auctions and reopen the auction house before retrying.

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

## Publish to WoWInterface

[Goldbook on WoWInterface](https://www.wowinterface.com/downloads/info27272-Goldbook.html)
is project `27272`; its initial version was uploaded through the website. The
addon mirror's repository variable `WOWINTERFACE_PROJECT_ID` selects this
project. Without that variable the workflow stays disabled.

The separate **Publish to WoWInterface** workflow starts after **Package addon
release** succeeds, including its CurseForge upload or verified receipt. It
has its own `wowinterface` approval and concurrency group. Approval delays,
failed uploads and moderation cannot block promotion, tagging or the next
release. Retry this workflow separately after checking the project page.

It checks out the successful run's exact commit and downloads its GitHub
release ZIP. Before uploading, it compares the ZIP with that commit's package
and verifies its CurseForge receipt. It publishes those same bytes through
the [WoWInterface update API](https://www.wowinterface.com/forums/showthread.php?t=51835).
Store `WOWINTERFACE_API_TOKEN` only in the protected `wowinterface` environment,
restricted to `main`, with approval by `jkc-be` and administrator bypass off.
The token is passed only to the upload step, in an HTTPS header. Redirects
are refused and response bodies and network error details are withheld.

The uploader updates the file, version and changelog. It preserves the title,
description, images and game compatibility selected on the project page.
WoWInterface currently has no compatibility option for the 1.60 Forever
client, so the description states the requirement and the uploader does not
substitute a different game version.

An accepted upload adds `wowinterface.json` to the GitHub release with the
project ID, version and ZIP's SHA-256. A matching receipt skips repeat uploads
independently of CurseForge. Acceptance can still require moderator review.
If the upload or receipt step fails, inspect the WoWInterface entry before
retrying. A lost response can leave the file submitted without a receipt.

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
luajit tests/auctionhouse.lua
python3 -m unittest discover -s tests -p 'test_*.py'
```

## License

Copyright (c) 2026 jkc-be. All rights reserved. See [LICENSE](LICENSE).
