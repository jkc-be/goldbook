# Classic profession item catalog

`professions.json` contains item IDs grouped by profession and role: materials,
recipe items, and crafted products. A material can belong to several professions.
The web API and addon use the same generated catalog. AtlasLoot is not required
at runtime.

The source is the factual item, recipe, and reagent data in the installed
AtlasLoot Classic Forever 1.60.1 snapshot's `Data/Profession.lua` and
`Data/Recipe.lua`. The JSON records SHA-256 hashes of those two source files.
Only their `CLASSIC` tables are used. No item names or translated descriptions
are copied. AtlasLoot's recipe index also contains some finished goods; the
generator excludes those from the recipe role when they are crafting outputs.

The catalog has twelve lists: Alchemy, Blacksmithing, Cooking, Enchanting,
Engineering, First Aid, Fishing, Leatherworking, Mining, Poisons, Skinning, and
Tailoring. Fishing contains recipe books only. Gathering loot is not inferred
from an item's name. New, seasonal, or expansion-specific items absent from the
source remain in the unfiltered list.

AtlasLoot has no Skinning data, so Skinning's materials come from
`skinning.json`, a hand-kept list of item IDs. An item is listed when its
Wowhead Classic page has a "Skinned from" tab. Wool Cloth is left out because
only sheep yield it and tailors use it, as are two junk items seen skinned
once: Chipped Boar Tusk and Broken Fang. Drops that are merely leather, such as
Raptor Hide, and leathers made by crafting are not skinned and stay out.
Skinned leathers also stay in the lists of the professions that use them. To
refresh Skinning, edit `skinning.json`, update its `source` line with the date
checked, and regenerate. The generator stops with an error if AtlasLoot ever
lists Skinning itself.

Refresh both the JSON and Lua data from a local AtlasLoot snapshot:

```sh
python3 scripts/generate-profession-catalog.py --atlasloot-data "/path/to/AtlasLootClassic/Data"
```

Regenerate both from the committed JSON and `skinning.json`:

```sh
python3 scripts/generate-profession-catalog.py
```

Verify that both representations agree and exercise the filters through the
addon UI and the real server API:

```sh
cargo build --locked
python3 scripts/verify-professions.py
```
