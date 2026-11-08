# Battle.net auction data

This page describes the auction data that the Battle.net Game Data API returns for WoW Forever's EU auction houses: the requests, the JSON, the fields, and what one snapshot holds. Blizzard has not documented the Forever routes, so everything here is observed behavior and can change without notice.

The examples and counts come from one snapshot of house 113, the EU PvP Horde auction house, with `Last-Modified` `Sun, 8 Nov 2026 09:12:14 GMT`. `scripts/probe-forever-ah.py eu OUT` fetched it at 10:04 UTC on 2026-11-08. The API sends no item names; the names below come from Goldbook's `/api/export`, whose newest EU PvP Horde scan is this snapshot. [Regenerate the numbers](#regenerate-the-numbers) lists the commands that produce each count from a probe's output.

For the house-to-shard mapping, the ruleset comparison, and the server's poller, see [Battle.net auction API for WoW Forever](../ah-api/README.md).

## A house takes two requests

All routes are on `https://eu.api.blizzard.com`. Each request needs `?namespace=dynamic-forever-eu` and an `Authorization: Bearer` header. A poller that knows its house ID needs only requests 4 and 5.

| # | Request | Response |
|---|---|---|
| 1 | `POST https://oauth.battle.net/token` with `grant_type=client_credentials` | `access_token` and `expires_in` `86399`. |
| 2 | `GET /data/wow/ruleset/index` | Rulesets 1 (PvP), 2 (Normal), 3 (Roleplay), and 15 (Roleplay PvP). |
| 3 | `GET /data/wow/ruleset/1/auctions/index` | 15 houses, each with `id`, a localized `name`, and `key.href`. |
| 4 | `GET /data/wow/ruleset/1/auctions/113` | Regular listings and a `commodities.href`. 10,749,306 bytes, 939,533 with gzip. |
| 5 | `GET /data/wow/ruleset/1/auctions/113/commodities` | Commodity listings. 4,871,452 bytes, 532,775 with gzip. |

The ruleset in the path does not select the market. All four rulesets list the same houses with the same listings.

These requests fail:

| Request | Status |
|---|---|
| `GET /data/wow/ruleset/1/auctions` (no trailing slash) | 404, empty body |
| `GET /data/wow/realm/index` | 404 |
| `GET /data/wow/connected-realm/index` | 404 |
| `GET /data/wow/auctions/commodities` (retail's region-wide route) | 404 |
| A house route with `namespace=dynamic-forever-us` on the EU host | 403 |

## The house response wraps the listings

The house response has the top-level keys `_links`, `auctions`, `commodities`, `id`, `name`, and `ruleset`. `name` holds 12 locales. The excerpt keeps two locales and the first two listings:

```json
{
	"_links": { "self": { "href": "https://eu.api.blizzard.com/data/wow/ruleset/1/auctions/113?namespace=dynamic-forever-eu" } },
	"id": 113,
	"name": { "en_US": "Horde Auction House", "de_DE": "Auktionshaus der Horde" },
	"commodities": { "href": "https://eu.api.blizzard.com/data/wow/ruleset/1/auctions/113/commodities?namespace=dynamic-forever-eu" },
	"ruleset": { "href": "https://eu.api.blizzard.com/data/wow/ruleset/1?namespace=dynamic-forever-eu" },
	"auctions": [
		{ "id": 10720850, "item": { "id": 211855 }, "buyout": 1000, "quantity": 1, "time_left": "SHORT" },
		{ "id": 10720968, "item": { "id": 1499, "context": 1, "modifiers": [{ "type": 28, "value": 5244 }] }, "buyout": 100, "quantity": 1, "time_left": "SHORT" }
	]
}
```

The commodity response has only `_links` and `auctions`:

```json
{
	"_links": { "self": { "href": "https://eu.api.blizzard.com/data/wow/ruleset/1/auctions/113/commodities?namespace=dynamic-forever-eu" } },
	"auctions": [
		{ "id": 10721149, "item": { "id": 5635 }, "quantity": 1, "unit_price": 53, "time_left": "SHORT" },
		{ "id": 10721406, "item": { "id": 10978 }, "quantity": 1, "unit_price": 100000, "time_left": "SHORT" }
	]
}
```

An empty house, such as 112, 115, or 118, answers 200 without an `auctions` key. Its commodity response contains only `_links`.

## Each listing is one auction

All prices are asking prices in copper. 1 gold is 100 silver, and 1 silver is 100 copper.

A regular listing with only an item ID. This Linen Bag costs 300 copper (3 silver):

```json
{ "id": 11458294, "item": { "id": 4238 }, "buyout": 300, "quantity": 1, "time_left": "LONG" }
```

A regular listing with `context` and `modifiers`. These Calico Pants carry modifier type 28, the only modifier type in the snapshot:

```json
{ "id": 10720968, "item": { "id": 1499, "context": 1, "modifiers": [{ "type": 28, "value": 5244 }] }, "buyout": 100, "quantity": 1, "time_left": "SHORT" }
```

A regular listing for a random-suffix variant. Item 6337 is Infantry Leggings, which come as "of the Owl", "of the Eagle", "of the Whale", "of the Bear", and more. `bonus_lists` selects the variant, but the mapping from bonus ID to suffix is unknown:

```json
{ "id": 10722658, "item": { "id": 6337, "bonus_lists": [12728] }, "buyout": 300, "quantity": 1, "time_left": "SHORT" }
```

A regular listing with a bid. These Tribal Pants have a bid of 700 copper and a buyout of 900 copper:

```json
{ "id": 11146728, "item": { "id": 3287 }, "bid": 700, "buyout": 900, "quantity": 1, "time_left": "MEDIUM" }
```

A commodity listing. This is a stack of 54 Rough Stone at 100 copper each:

```json
{ "id": 10722245, "item": { "id": 2835 }, "quantity": 54, "unit_price": 100, "time_left": "SHORT" }
```

The fields and how often each appears in house 113:

| Field | List | Value | Rows in house 113 |
|---|---|---|---|
| `id` | both | Auction ID. | Every row. 10,720,850 to 20,092,494. |
| `item.id` | both | Item ID. No name, icon, or quality. | Every row. |
| `item.context` | regular | A number. | 17,467 of 116,767 (15.0%). Values 1, 11, 14, and 75. |
| `item.modifiers` | regular | A list of `{ "type", "value" }`. | 13,183 (11.3%). Type 28 only. |
| `item.bonus_lists` | regular | Bonus IDs that select a random-suffix variant. | 20,188 (17.3%). One ID each, 12688 to 12920. |
| `buyout` | regular | Buyout for the whole auction. | 116,767 (100%). |
| `bid` | regular | Current bid. | 347 (0.3%). |
| `unit_price` | commodities | Price per unit. | 56,945 of 56,945 (100%). |
| `quantity` | both | Units in the auction. | Regular: always 1. Commodities: 1 to 9,800. |
| `time_left` | both | `SHORT`, `MEDIUM`, `LONG`, or `VERY_LONG`. | Every row. |

A commodity listing's `item` holds only `id`. No item ID appears in both lists. A regular listing without `buyout` is possible: the run on 2026-11-06 found 3 in house 110. House 113 had none in this snapshot.

## One snapshot of house 113

| List | Listings | Items | Units |
|---|---|---|---|
| Regular | 116,767 | 2,845 | 116,767 |
| Commodities | 56,945 | 865 | 1,057,020 |

`time_left` is a band, not a time:

| `time_left` | Regular | Commodities |
|---|---|---|
| `SHORT` | 7,267 (6.2%) | 3,536 (6.2%) |
| `MEDIUM` | 19,028 (16.3%) | 10,795 (19.0%) |
| `LONG` | 70,930 (60.7%) | 35,019 (61.5%) |
| `VERY_LONG` | 19,542 (16.7%) | 7,595 (13.3%) |

Commodity listings by `quantity`:

| Quantity | Listings |
|---|---|
| 1 | 18,376 |
| 2 to 5 | 18,993 |
| 6 to 10 | 7,347 |
| 11 to 20 | 7,959 |
| 21 to 50 | 2,433 |
| 51 to 100 | 832 |
| 101 to 200 | 660 |
| over 200 | 345 |

The items with the most listings:

| Regular | Listings | Commodities | Listings |
|---|---|---|---|
| Linen Bag (4238) | 3,975 | Blood Shard (5075) | 966 |
| Lesser Magic Wand (11287) | 2,781 | Crisp Spider Meat (1081) | 907 |
| Red Linen Bag (5762) | 2,660 | Shadowgem (1210) | 816 |
| Copper Rod (6217) | 2,352 | Linen Cloth (2589) | 651 |
| Greater Magic Wand (11288) | 2,091 | Bear Meat (3173) | 590 |

## An item's listings form its order book

Group an item's listings by unit price to get its order book. These are the eight cheapest price levels of Mageweave Cloth (4338), out of 42:

| Unit price | Units | Listings |
|---|---|---|
| 758 | 106 | 9 |
| 760 | 235 | 26 |
| 771 | 288 | 9 |
| 772 | 327 | 12 |
| 775 | 57 | 5 |
| 776 | 100 | 7 |
| 777 | 558 | 28 |
| 785 | 202 | 19 |

Goldbook turns the book into the row that an in-game full scan uploads: the minimum unit price, a market value, the total units, and the number of auctions. `crates/goldbook-core/src/market.rs` computes the market value. It averages the cheapest 15% of units, extends to 30% of units until the price rises more than 20% from one level to the next, and leaves out prices more than 1.5 standard deviations from that window's mean. The rows that Goldbook stored for this snapshot:

| Item | Minimum | Market value | Units | Auctions |
|---|---|---|---|---|
| Linen Cloth (2589) | 23 | 25 | 18,242 | 651 |
| Wool Cloth (2592) | 130 | 130 | 3,881 | 161 |
| Silk Cloth (4306) | 40 | 243 | 4,269 | 205 |
| Mageweave Cloth (4338) | 758 | 770 | 3,733 | 352 |
| Iron Ore (2772) | 477 | 499 | 3,705 | 216 |

Silk Cloth shows why the market value differs from the minimum. Two units at 40 copper sit below 298 units at 240 copper, so the 40 copper price falls outside 1.5 standard deviations and the market value is 243.

## All EU houses publish in the same minutes

The index lists 15 houses. By ID they form five sets of an Alliance, a Horde, and a Blackwater house. Sizes add both lists.

| Set | House | Name | Regular | Commodities | Bytes | Bytes with gzip | `Last-Modified` |
|---|---|---|---|---|---|---|---|
| 110/113/116 | 110 | Alliance Auction House | 95,525 | 48,252 | 12,834,449 | 1,223,385 | 09:12:13 |
| | 113 | Horde Auction House | 116,767 | 56,945 | 15,620,758 | 1,472,308 | 09:12:14 |
| | 116 | Blackwater Auction House | 2,926 | 5,161 | 717,210 | 80,859 | 09:12:07 |
| 111/114/117 | 111 | Alliance Auction House | 110,982 | 50,925 | 14,335,260 | 1,357,328 | 09:12:13 |
| | 114 | Horde Auction House | 102,369 | 48,786 | 13,489,094 | 1,274,952 | 09:12:13 |
| | 117 | Blackwater Auction House | 2,838 | 5,357 | 722,349 | 81,524 | 09:12:07 |
| 112/115/118 | 112 | Alliance Auction House | 0 | 0 | 929 | 635 | 09:12:07 |
| | 115 | Horde Auction House | 0 | 0 | 891 | 602 | 09:12:07 |
| | 118 | Blackwater Auction House | 0 | 0 | 955 | 657 | 09:12:07 |
| 119/120/121 | 119 | Alliance Auction House | 11,953 | 8,833 | 1,837,943 | 189,937 | 09:12:08 |
| | 120 | Horde Auction House | 7,763 | 4,806 | 1,120,229 | 115,451 | 09:12:08 |
| | 121 | Blackwater Auction House | 109 | 236 | 31,530 | 4,646 | 09:12:07 |
| 123/124/125 | 123 | Alliance Auction House | 8,023 | 7,759 | 1,406,540 | 149,607 | 09:12:08 |
| | 124 | Horde Auction House | 8,000 | 6,917 | 1,333,779 | 139,678 | 09:12:08 |
| | 125 | Blackwater Auction House | 144 | 261 | 37,268 | 5,446 | 09:12:07 |

The API does not say which shard uses which house. [Which house a shard uses](../ah-api/README.md#which-house-a-shard-uses) describes how Goldbook matched house 113 to EU4 PvP Horde.

## The headers tell when a snapshot changed

| Header | Value | Meaning |
|---|---|---|
| `Last-Modified` | `Sun, 8 Nov 2026 09:12:14 GMT` | The snapshot time, on each list. The day has one digit below 10. The two lists of a house can differ by a second: house 110's regular list read 09:12:13 and its commodity list 09:12:12. |
| `Cache-Control` | `public, max-age=86400` | On house routes, although a house changes about once an hour. |
| `If-Modified-Since` (request) | The stored `Last-Modified` | 304 with an empty body when the snapshot has not changed. House 110 answered in 0.16 seconds. |
| `ETag` | absent | |
| `Content-Encoding` | `gzip` | When the request accepts gzip. The lists compress about 10 to 1. |

## The data leaves out

- Item names, icons, and quality.
- The suffix name of a random-suffix variant. The API's bonus IDs (12688 to 12920 here) are not the suffix IDs that the addon uses in item keys (14296 to 14473).
- Sellers.
- Sales. A listing that is missing from the next snapshot sold, expired, or was cancelled.
- Bid history and auction start or end times.
- The shard or realm that uses a house.

## Regenerate the numbers

Fetch a snapshot of every house:

```sh
scripts/probe-forever-ah.py eu OUT
```

`OUT/summary.json` holds the request log and each house's listing counts. Set the paths of house 113's two lists:

```sh
R=OUT/raw/data_wow_ruleset_1_auctions_113.dynamic-forever-eu.json
C=OUT/raw/data_wow_ruleset_1_auctions_113_commodities.dynamic-forever-eu.json
```

Listings, items, and units of each list:

```sh
for f in "$R" "$C"; do jq -c '{listings: (.auctions | length), items: ([.auctions[].item.id] | unique | length), units: ([.auctions[].quantity] | add)}' "$f"; done
```

`time_left` of each list:

```sh
for f in "$R" "$C"; do jq -c '[.auctions[].time_left] | group_by(.) | map({(.[0]): length}) | add' "$f"; done
```

Optional fields of regular listings:

```sh
jq -c '.auctions | {context: map(select(.item | has("context"))) | length, modifiers: map(select(.item | has("modifiers"))) | length, bonus_lists: map(select(.item.bonus_lists | length > 0)) | length, bid: map(select(has("bid"))) | length, no_buyout: map(select(has("buyout") | not)) | length, bonus_ids: ([.[].item.bonus_lists[]?] | [min, max]), modifier_types: ([.[].item.modifiers[]?.type] | unique), contexts: ([.[].item.context // empty] | unique)}' "$R"
```

Commodity listings by `quantity`:

```sh
jq -c '[.auctions[].quantity | if . == 1 then "1" elif . <= 5 then "2-5" elif . <= 10 then "6-10" elif . <= 20 then "11-20" elif . <= 50 then "21-50" elif . <= 100 then "51-100" elif . <= 200 then "101-200" else "over 200" end] | group_by(.) | map({(.[0]): length}) | add' "$C"
```

Items in both lists:

```sh
jq -n --slurpfile r "$R" --slurpfile c "$C" '([$r[0].auctions[].item.id] | unique) as $a | ([$c[0].auctions[].item.id] | unique) as $b | $a - ($a - $b) | length'
```

The order book of one commodity, as `[unit price, units, listings]`:

```sh
jq -c --argjson item 4338 '[.auctions[] | select(.item.id == $item)] | group_by(.unit_price) | map([.[0].unit_price, (map(.quantity) | add), length])' "$C"
```

Every house:

```sh
jq -r '.houses[] | select(.ruleset == 1) | [.house, .name.en_US, (.regular.count // 0), (.commodities.count // 0), .call.bytes + (.commodities_call.bytes // 0), .call.bytes_on_wire + (.commodities_call.bytes_on_wire // 0), .call.last_modified] | @tsv' OUT/summary.json
```

The stored rows come from Goldbook's export. The export shows the newest scan, so these rows match the snapshot only while it is the newest scan of EU PvP Horde:

```sh
curl -s -A goldbook-scripts 'https://app.jkc-be.com/goldbook/api/export?realm=CAMWOWEU4Realm8PvP&faction=Horde' | jq -c '.scannedAt, (.items | {"2589", "2592", "4306", "4338", "2772"} | map_values(.price[0:3] + [.price[4]]))'
```
