# Server data for the addon

The addon cannot use the network, and the game overwrites `GoldbookDB` when it logs out. To give the addon prices that other players scanned, the desktop app writes a Lua file into the addon folder:

```
<WoW>/<flavor>/Interface/AddOns/Goldbook/ServerData.lua
```

`Goldbook.toc` lists `ServerData.lua` before `Database.lua`, so the game loads the file at login and at `/reload`. The file sets one global, `GoldbookServerData`. The addon ships a stub that sets `GoldbookServerData = nil`, which is what the addon sees until the app has written the file.

Data flows in three steps:

1. The server answers `GET /api/export` with one realm's prices and history as JSON.
2. The app (`goldbook_sync::write_server_data`) fetches the export for each realm in the flavor's SavedVariables and writes `ServerData.lua`.
3. The addon merges `GoldbookServerData` into `GoldbookDB` when it loads, by the [merge rules](#merge-rules).

## The export endpoint

`GET /api/export?realm=<realm>&faction=<faction>` is public and read-only, like `/api/prices`. It needs no login and no upload token.

When the request's `Accept-Encoding` names `gzip`, the server compresses the body and answers `Content-Encoding: gzip`. Every export answer carries `Vary: Accept-Encoding`. The server compresses the body itself, because the Traefik labels in `server/compose*.yaml` have no `compress` middleware. The sync client asks for gzip and decodes it.

| Status | Body |
| --- | --- |
| 200 | The realm's data, described below. |
| 400 | `{"error":"realm is required"}` or `{"error":"faction is required"}`. |
| 404 | `{"error":"no scans for this realm and faction"}`. |

A 200 body looks like this:

```json
{
  "realm": "Faramon",
  "faction": "Horde",
  "scannedAt": 1760090000,
  "items": {
    "2589": {
      "name": "Linen Cloth",
      "quality": 1,
      "price": [100, 100, 4, 1760090000, 105, 1760090000],
      "hours": [[488912, 110, 42, 0], [488913, 100, 100, 105]],
      "days": [[20371, 100, 100, 105]]
    }
  }
}
```

The fields mean the following:

- `scannedAt` is the time of the realm's newest scan, in unix seconds. Both history windows end at this scan, not at the time of the request.
- `items` maps each item key to the item's data, sorted by key. An item key is the addon's key from `Codec.ItemKey`: the item ID, or `itemID:suffix` for an item with a random suffix.
- `name` and `quality` come from the server's item names. Both are `null` when no upload named the item.
- `price` is `[min, qty, n, seen, mv, mvAt]`. `min`, `qty` and `n` are the lowest buyout, the quantity and the auction count of the item's newest row, and `seen` is that row's scan time. `n` is 0 when that row came from a quick scan. `mv` is the market value of the newest row whose market value is above 0, and `mvAt` is that row's scan time. Both are 0 when no full scan in the window measured the item.
- `hours` holds one `[hour, min, qty, mv]` entry per unix hour (`floor(time / 3600)`) in which a scan saw the item, oldest first. It covers the 168 hours that end with the hour of `scannedAt`.
- `days` holds one `[day, min, qty, mv]` entry per UTC day number (`floor(time / 86400)`) in which a scan saw the item, oldest first. It covers the day of `scannedAt` and the 60 days before it, the same window as `KEPT_DAYS` in `Database.lua`. `days` overlaps `hours`, so that the addon can merge daily history without adding up hours.

In an `hours` or `days` entry, `min` is the lowest buyout any scan saw in that hour or day, and `qty` is the quantity of the row that had it. When rows tie on `min`, the earlier row wins. A day's `min` is its lowest buyout, the same daily low that `/api/trends` gives the website. `mv` is the market value of the newest row in that hour or day whose market value is above 0, or 0 when there is none.

Rows are ordered by scan time. Two scans can have the same time, and then the scan that the server stored first counts as the earlier one. "Newest" and "earlier" in this section follow that order.

All prices are in copper. The export reads only the scans from the day of `scannedAt` and the 60 days before it. An item that none of those scans saw is not in `items`.

## The file the app writes

`ServerData.lua` sets `GoldbookServerData` to a table of this shape:

```lua
GoldbookServerData = {
  version = 1,
  server = "https://app.jkc-be.com/goldbook",
  items = {
    ["2589"] = "1|Linen Cloth",
  },
  realms = {
    ["Faramon-Horde"] = {
      scannedAt = 1760090000,
      prices = { ["2589"] = "100,100,4,1760090000,105,1760090000" },
      hours = { ["2589"] = "488912:110:42:0,488913:100:100:105" },
      days = { ["2589"] = "20371:100:100:105" },
    },
  },
}
```

The fields mean the following:

- `version` is 1. A change to this shape that an older addon cannot read raises it. The addon ignores a table whose `version` it does not know.
- `server` is the server address the app is set to, as Settings shows it.
- `items[itemKey]` is `"quality|name"`, the encoding of `GoldbookDB.items`. Items without a name or a quality on the server are not in `items`. When realms name an item differently, the first realm key in sorted order wins.
- `realms` is keyed by the addon's realm key, `ns.RealmKey()`: the realm as `GetNormalizedRealmName()` gives it, a hyphen, and the faction. The app splits a key at its last hyphen to get the realm and the faction for the export.
- `scannedAt` is the export's `scannedAt`.
- `prices[itemKey]` is the export's `price` joined with commas. These are the first six fields of `Codec.EncodePrice`, in the same order, so `Codec.DecodePrice(packed .. ";")` decodes the string into a record with empty `days` and `ladder`.
- `hours[itemKey]` is the export's `hours` as `"hour:min:qty:mv,..."`, oldest first, in the encoding of `Codec.HistoryDay` with an hour number in place of the day number. An item that no scan saw in the hour window has no `hours` entry.
- `days[itemKey]` is the export's `days` as `"day:min:qty:mv,..."`, oldest first. This string is the encoding of `GoldbookDB.history[realmKey][itemKey]`, so `Codec.DecodeHistory` reads it.

The file holds no clock time of its own. The same server data gives the same bytes, which lets the app skip a write when nothing changed.

The file does not hold the table as one constructor. It fills the table in functions of at most 10,000 entries each. LuaJIT allows 65,536 string constants in one function, and a realm with 15,000 items already needs about 75,000. The table that the file builds is the shape above.

## How the app writes the file

The app writes `ServerData.lua` after a sync pass that uploaded without errors. In the background it does this at most once every 15 minutes for each game flavor, or once per sync interval when the interval is longer. **Sync now** and `goldbook-sync --once` write it after every pass whose uploads did not fail, whatever the interval.

For each flavor folder, the app does the following:

1. Reads every `WTF/Account/*/SavedVariables/Goldbook.lua` in the flavor. It collects the realm keys of `GoldbookDB.prices`, `GoldbookDB.scanned`, and the `realm` and `faction` of each entry in `GoldbookDB.characters`. It removes spaces from a character's realm, because older addon versions saved the realm's display name.
2. Fetches `/api/export` for each realm key, in sorted order. A realm that answers 404 is left out of the file.
3. Writes nothing when the flavor has no `Interface/AddOns/Goldbook` folder, when the server has data for none of the realms, or when any export fails. A failed export keeps the previous file, so a network error does not remove realms from it.
4. Builds the file with sorted keys and escapes every string. It writes the file only when its bytes differ from the installed file. It writes a temporary file in the addon folder and renames it over `ServerData.lua`, so the game never reads half a file.

The app never writes SavedVariables. A failed export does not stop or retry uploads. The app logs the failure and shows it in its status line.

## The installer keeps the written file

`goldbook_sync::install_addon` replaces the whole `Goldbook` folder, which removes files that a new version no longer ships. `ServerData.lua` is the exception. When the installed folder has a `ServerData.lua`, the update keeps that file and leaves out the stub from the new version. The stub only fills a folder that has no `ServerData.lua`.

The rule needs no version comparison. The app writes the file, so a newer one is always the installed one. When an update changes `version`, the new addon ignores the old file until the next sync pass rewrites it. An addon manager that unpacks a release ZIP puts the stub back. The next sync pass rewrites the file, because the stub's bytes differ from what the app renders.

## Merge rules

`Database.MergeServer` merges the file into `GoldbookDB` when the addon loads, right after `Database.Init`. It follows these rules:

- A local price wins when its `seen` is newer than or equal to the server's `seen`. Otherwise the server's `min`, `qty`, `n` and `seen` replace it, the ladder becomes empty, and the record's recent days are the lows of the merged history's last 14 days. The server's `mv` and `mvAt` replace the local ones only when the server's `mvAt` is newer, also when the local price wins.
- Server days fill only the days that the local history lacks. A day that both have keeps the local entry. The merged history stays sorted by day and keeps only the last `KEPT_DAYS` days. Server hours fill `GoldbookDB.hours`, which uses the same encoding, the same way, and keep the last 168 hours.
- Server names fill only the items that `GoldbookDB.items` lacks.
- The merge is idempotent. A second merge of the same file after `/reload` changes nothing, because every entry it would copy is already there or lost to a newer local one. The addon skips a realm whose `scannedAt` equals the one it merged last, kept in `serverMerged[realmKey]`.
- The addon marks a price it took from the server with the server's `seen` in `fromServer[realmKey][itemKey]`. The tooltip then says "from the server" after the age of the price, and the item view's Listed card says "From the server". A local scan of the item clears the mark. Chat says how many prices the addon took, when it took any.
- Merging the server data does not change `scanned`, the time of the newest scan here, so the quick scan when the auction house opens still runs.

## Limitations

- An addon install that runs while the app writes `ServerData.lua` can lose the new file. The installer copies the installed file before it swaps the folders. If the app renames a new file into place between those two steps, the swap removes it. The next download writes it again, which in the background can be 15 minutes later.
- A download that is running when the sync service stops still finishes and writes its file. After a server change in Settings, the old server's data can therefore land just before the new server's first download replaces it.
