# Battle.net auction API for WoW Forever

This page records what the Battle.net Game Data API returned for WoW Forever's EU auction houses in a test run on 2026-11-06. It backs [issue #67](https://github.com/jkc-be/goldbook/issues/67), which plans a server poller for these snapshots. Blizzard has not documented the Forever routes, so everything here is observed behavior and can change without notice.

The run used the server's Battle.net client (`BNET_CLIENT_ID`, client-credentials grant) against `https://eu.api.blizzard.com` with the namespace `dynamic-forever-eu`. It made two full passes, at 09:45 and 09:50 UTC. Both passes read the same auction snapshot, whose `Last-Modified` was 09:17 UTC. Requests made in both passes got the same results.

## Run it again

```sh
scripts/probe-forever-ah.py eu OUT
scripts/match-forever-house.py OUT https://app.jkc-be.com/goldbook CAMWOWEU4Realm8PvP Horde
```

`probe-forever-ah.py` reads `BNET_CLIENT_ID` and `BNET_CLIENT_SECRET` from the environment or from `server/.env.local`. It saves every response body under `OUT/raw/` and writes `OUT/summary.json`. A pass makes about 146 read-only requests and downloads about 14 MB with gzip, because it fetches every house through all four rulesets. `match-forever-house.py` compares one realm's latest scan, from the server's public `/api/export`, with each house in `OUT`.

The python.org build of Python on macOS has no CA certificates. If a script fails with `CERTIFICATE_VERIFY_FAILED`, run it with `SSL_CERT_FILE=/etc/ssl/cert.pem`.

## Summary

- The Forever auction routes work with our client. Each house has a regular list and a commodity list, and 12 of the 15 EU houses had listings.
- The ruleset in the URL does not select the market. All four rulesets list the same 15 houses and return the same listings for each, apart from one or two listings in three houses.
- Regular listings always have `quantity` 1, commodity listings carry the stacks, and no item appears in both lists.
- `If-Modified-Since` returns 304 when the snapshot has not changed.
- Our Horde scans from `CAMWOWEU4Realm6PvP` and `CAMWOWEU4Realm8PvP` match house 113 best. This is likely but not confirmed, because the scans were 11 hours older than the snapshot.
- The API's bonus IDs for item variants are not the suffix IDs the addon uses in its item keys. How to map one to the other is unknown.

## Routes

All routes are relative to `https://eu.api.blizzard.com` and need `?namespace=dynamic-forever-eu` and an `Authorization: Bearer` header. The token lasts 24 hours (`expires_in` 86399).

| Route | Status | Notes |
|---|---|---|
| `/data/wow/region/index` | 200 | Lists one region, 93. |
| `/data/wow/region/93` | 200 | `CAMWOW Europe`, tag `EU`, `patch_string` `1.60.1`. |
| `/data/wow/ruleset/index` | 200 | Rulesets 1, 15, 3 and 2. |
| `/data/wow/ruleset/{rulesetId}` | 200 | Name, status and an `auctions.href`. |
| `/data/wow/ruleset/{rulesetId}/auctions/` | 200 | The `auctions.href` from the ruleset. Same body as `/auctions/index`. |
| `/data/wow/ruleset/{rulesetId}/auctions/index` | 200 | The 15 houses, each with `id`, `name` and `key.href`. |
| `/data/wow/ruleset/{rulesetId}/auctions` | 404 | Without the trailing slash. Empty body. |
| `/data/wow/ruleset/{rulesetId}/auctions/{houseId}` | 200 | Regular listings, and a `commodities.href`. |
| `/data/wow/ruleset/{rulesetId}/auctions/{houseId}/commodities` | 200 | Commodity listings. |
| `/data/wow/ruleset/1/auctions/122` | 404 | A house ID not in the index. |
| `/data/wow/ruleset/4/auctions/110` | 404 | A ruleset ID not in the index. |
| `/data/wow/ruleset/1/auctions/110` with `dynamic-forever-us` | 403 | The other region's namespace on the EU host. |
| `/data/wow/realm/index` | 404 | Forever has no realm index. |
| `/data/wow/connected-realm/index` | 404 | Forever has no connected realms. |
| `/data/wow/auctions/commodities` | 404 | Retail's region-wide commodity route. |

## Rulesets

| ID | Name | Status |
|---|---|---|
| 1 | PvP | UP |
| 2 | Normal | UP |
| 3 | Roleplay | UP |
| 15 | Roleplay PvP | UP |

## Auction houses

The index lists 15 houses. By ID they fall into five sets of Alliance, Horde and Blackwater houses: 110/113/116, 111/114/117, 112/115/118, 119/120/121 and 123/124/125. The counts below were read through ruleset 1. "Items" counts distinct item IDs across both lists.

| House | Faction | Regular | Commodities | Items | Uncompressed | gzip |
|---|---|---|---|---|---|---|
| 110 | Alliance | 56,335 | 29,263 | 2,072 | 7.4 MB | 730 kB |
| 111 | Alliance | 62,120 | 28,146 | 2,023 | 7.7 MB | 761 kB |
| 112 | Alliance | none | none | | | |
| 113 | Horde | 71,844 | 27,811 | 1,964 | 8.7 MB | 838 kB |
| 114 | Horde | 60,214 | 23,889 | 1,894 | 7.3 MB | 705 kB |
| 115 | Horde | none | none | | | |
| 116 | Blackwater | 898 | 1,638 | 568 | 223 kB | 27 kB |
| 117 | Blackwater | 787 | 1,163 | 482 | 169 kB | 21 kB |
| 118 | Blackwater | none | none | | | |
| 119 | Alliance | 6,017 | 5,056 | 885 | 949 kB | 103 kB |
| 120 | Horde | 3,561 | 2,520 | 636 | 526 kB | 57 kB |
| 121 | Blackwater | 26 | 24 | 40 | 6 kB | 2 kB |
| 123 | Alliance | 4,017 | 3,990 | 781 | 688 kB | 76 kB |
| 124 | Horde | 4,018 | 3,175 | 746 | 623 kB | 68 kB |
| 125 | Blackwater | 22 | 52 | 41 | 7 kB | 2 kB |

All 15 houses come to 34.3 MB uncompressed and 3.4 MB with gzip, in 30 requests that took about 11 seconds.

The empty houses 112, 115 and 118 answer 200 with `_links`, `commodities`, `id`, `name` and `ruleset`, and no `auctions` key. Their commodity list answers 200 with only `_links`. Read a missing `auctions` key as an empty house, not an error.

## The ruleset in the URL

Every ruleset's index lists the same 15 houses. Fetching a house through each of the four rulesets returned the same listings for 12 houses. The response differs only in `_links.self` and `ruleset.href`, which echo the URL that was asked for.

The other three differed by one or two listings out of 30,000 to 70,000, with the same `Last-Modified`:

- House 110 through ruleset 15 had one extra listing, and its commodity list through ruleset 2 lacked two.
- House 113 through ruleset 15 had one extra listing.
- House 114 through ruleset 15 had one listing whose `time_left` read `MEDIUM`, while the other rulesets showed `SHORT`.

Both passes, five minutes apart, returned exactly these differences. Each URL seems to serve a copy cached at a slightly different moment of the same snapshot. A ruleset choosing a different market would differ by far more.

So region and house ID identify a market, and the ruleset is only part of the path. A poller should fetch each house once, always through the same ruleset, so that successive snapshots of a house come from the same URL.

## Listing fields

A house response has the top-level keys `_links`, `auctions`, `commodities`, `id`, `name` and `ruleset`. A commodity response has `_links` and `auctions`.

A regular listing:

```json
{ "id": 1556254, "item": { "id": 15477, "bonus_lists": [12725] }, "buyout": 300, "quantity": 1, "time_left": "LONG" }
```

- `quantity` was 1 on every regular listing in every house.
- `buyout` is missing on a few listings that have only a `bid`, for example 3 of 56,335 in house 110. `bid` appears on 0 to 200 listings per house. The in-game scanner skips listings without a buyout, and API rows should do the same.
- `item` can carry `bonus_lists`, `context` and `modifiers`. In house 113, 11,920 of 71,844 listings had a one-element `bonus_lists` and 5,661 had a `modifiers` entry of type 28.

A commodity listing:

```json
{ "id": 3344570, "item": { "id": 4537 }, "quantity": 1, "unit_price": 50, "time_left": "VERY_LONG" }
```

All prices are asking prices in copper. `time_left` is one of `SHORT`, `MEDIUM`, `LONG` and `VERY_LONG`.

To match the scanner, which stores `ceil(buyout / count)` per listing in `addon/Goldbook/Scanner.lua`, take the regular `buyout` as the unit price and the commodity `unit_price` as it is.

## Caching

- The house routes and the auctions index send `Cache-Control: public, max-age=86400` and a `Last-Modified` that matches the snapshot time, 09:17:16 to 09:17:22 UTC in this run. Neither run saw a snapshot change, so how often snapshots change is not measured yet.
- Sending that `Last-Modified` back as `If-Modified-Since` returns 304 with an empty body. An older date returns 200.
- No route sends an `ETag`.
- The ruleset index and ruleset details send `max-age=30`, and their `Last-Modified` moves every 30 seconds.
- Every 200 response was gzip-compressed when asked for. The house lists compress about 10 to 1.

## Which house a shard uses

The client reports no house ID, so the mapping from shard to house has to come from the data. `match-forever-house.py` takes the realm's newest scan from the server, keeps the plain item IDs, and compares each item's minimum unit price with each house's minimum.

Both EU4 PvP shards give the same ranking, which fits with them sharing one auction house:

| House | Scan items found | Same minimum | Median \|ln(scan / house)\| |
|---|---|---|---|
| 113 | 93% | 34% | 0.18 |
| 114 | 90% | 28% | 0.24 to 0.25 |
| 111 | 79% | 25% | 0.33 to 0.34 |
| 110 | 79% | 23% | 0.34 to 0.36 |
| 119 | 41% | 16 to 17% | 0.56 |
| 120, 123, 124 | 34 to 40% | 9 to 11% | 0.69 |
| 116, 117 | 24 to 28% | 8 to 12% | 0.85 to 0.92 |
| 121, 125 | 2% | 0 to 3% | 1.29 to 1.61 |

A median of 0.18 means the two prices of a typical item are about 20% apart. On the roughly 905 items where houses 113 and 114 have different minimums, the scan matches 113 exactly 145 to 148 times and 114 79 times. As a control, the same comparison between the Alliance houses 110 and 111, which a Horde scan should match equally badly, gives 62 against 77.

The scans were taken at 22:13 and 22:19 UTC on 2026-11-05, 11 hours before the snapshot, so prices had time to move. Read this as "EU4 PvP Horde is probably house 113". If it is, EU4 PvP Alliance would be 110 and its Blackwater house 116, but there are no Alliance scans to check that.

## Item variants

The addon keys a variant as `itemID:suffix` (`Codec.ItemKey` in `addon/Goldbook/Codec.lua`). The API marks variants with `bonus_lists`. The two use different numbers: the API's bonus IDs ranged from 12688 to 12920, and the suffixes in production's `CAMWOWEU4Realm8PvP` scans range from 14296 to 14473. None of the 3,778 variant keys in that export appears as an item and bonus ID pair in the API. A fixed offset of about 1580 lines up some of them, but neighbouring offsets fit almost as well, so it proves nothing.

Until the mapping is known, API prices can only cover listings without `bonus_lists`.

## Differences from the community post

The [Reddit post](https://www.reddit.com/r/wowaddons/comments/1xofb73/how_to_access_the_wow_forever_auction_house_api/) summarized on issue #67 was right about the namespaces, the ruleset routes, the IDs and the response shapes. This run differs in these points:

- The ruleset's `auctions.href` works. It ends in `/auctions/` with a trailing slash, which returns the index. Only `/auctions` without the slash returns 404.
- Regular listings can have `bid`, and a few have `bid` without `buyout`.
- `item` also carries `context` and `modifiers`.
- House 116 was not the only house that matched across rulesets. All of them do, apart from the cache differences described above.

## Polling from the server

The server can poll these snapshots itself and store each one as a full scan. Polling is off by default. To switch it on, set `GOLDBOOK_BATTLENET_HOUSES` in the server's environment, beside `BNET_CLIENT_ID` and `BNET_CLIENT_SECRET`, which it uses to get its token:

```dotenv
GOLDBOOK_BATTLENET_HOUSES="EU PvP/Horde=113,EU PvP/Alliance=110"
```

Each comma-separated entry is `<house>/<faction>=<API house ID>`:

- The house is a server house name as `/api/realms` lists it, such as `EU PvP`. Its first word, `EU` or `US`, picks the API host and the namespace.
- The faction is `Alliance` or `Horde`.
- The API house ID is the `id` from the auctions index.

The server does not start when an entry is malformed, names a shard such as `CAMWOWEU4Realm8PvP` instead of its house, starts with another region, or repeats a house and faction. It also does not start when the variable is set and the client ID or secret is missing.

To find a house's API ID, take a scan of one of the house's shards that is newer than the snapshot, then run `probe-forever-ah.py` and `match-forever-house.py` as in [Run it again](#run-it-again). Configure the house that matches best. The IDs in the example above are the likely ones from [Which house a shard uses](#which-house-a-shard-uses), and are not confirmed.

Before switching it on, `scripts/verify-battlenet-auctions.py "EU PvP/Horde=113" CAMWOWEU4Realm6PvP` checks one entry end to end, with the client ID and secret in the environment. It polls the house into a throwaway server, compares every exported minimum with its own reading of the API, checks that Battle.net answers 304 to the stored time, syncs the shard into a `ServerData.lua`, and restarts the server to show that the same snapshot is not stored twice.

Every 10 minutes the server asks each configured house for its regular list through ruleset 1, with the time of the newest snapshot it stored as `If-Modified-Since`. When the snapshot is new, it fetches the commodity list too and stores both as one full scan, timed at the snapshot's `Last-Modified`, with the scanner `Battle.net`. The scan reaches the website, `/api/export` and the addon's `ServerData.lua` like a player's upload, and a player's scan that is newer keeps its prices. The server logs each stored snapshot and each failure in one line. A house that fails is tried again in the next pass.

The scans leave out:

- Listings with `bonus_lists`, because the API's bonus IDs do not map to the addon's item keys. See [Item variants](#item-variants).
- Listings without a buyout, as the in-game scanner does.
- Blackwater houses, because a server house has only Alliance and Horde.
- Item names. An item that no player has scanned has no name until one does.

## Open questions

- Confirm that EU4 PvP Horde is house 113, using a scan taken within an hour after a snapshot's `Last-Modified`, and find the Alliance house with an Alliance scan.
- Find which shards use the sets 111/114/117, 119/120/121 and 123/124/125, and what the empty set 112/115/118 is for.
- Measure how often a house's `Last-Modified` changes.
- Find how API bonus IDs map to the addon's suffix IDs.
- Repeat the run for US. The post reports the same house IDs there with different listings, and our client got 102,292 listings for US house 113.
