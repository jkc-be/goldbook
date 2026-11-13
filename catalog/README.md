# Classic profession catalogs

`professions.json` contains item IDs grouped by profession and role: materials,
recipe items, and crafted products. A material can belong to several professions.
The web API and addon use the same generated catalog. AtlasLoot is not required
at runtime.

The source is the factual item, recipe, and reagent data in the installed
AtlasLoot Classic Forever 1.60.1 snapshot's `Data/Profession.lua` and
`Data/Recipe.lua`. `professions.json` records the SHA-256 hashes of both files.
Only their `CLASSIC` tables are used. No item names or translated descriptions
are copied. AtlasLoot's recipe index also contains some finished goods; the
generator excludes those from the recipe role when they are crafting outputs.

The catalog has thirteen lists: Alchemy, Blacksmithing, Cooking, Enchanting,
Engineering, First Aid, Fishing, Herbalism, Leatherworking, Mining, Poisons,
Skinning, and Tailoring. Fishing contains recipe books only. Gathering loot is
not inferred from an item's name. New, seasonal, or expansion-specific items
absent from the source remain in the unfiltered list.

AtlasLoot has no gathering data, so Herbalism and Skinning take their
materials from `herbalism.json` and `skinning.json`, hand-kept lists of item
IDs. An item is in `herbalism.json` when its Wowhead Classic page has a
"Gathered from" tab listing herb nodes. Elemental Earth, Fire and Water are
left out because they come from other sources and herb nodes yield them in
about 0% of gathers. Blood Scythe is left out because it is a Zul'Gurub tool, not a
gathered herb. An item is in `skinning.json` when its Wowhead Classic page has
a "Skinned from" tab. Wool Cloth is left out because only sheep yield it and
tailors use it, as are two junk items seen skinned once: Chipped Boar Tusk and
Broken Fang. Drops that are merely leather, such as Raptor Hide, and leathers
made by crafting are not skinned and stay out. Gathered materials also stay in
the lists of the professions that use them. To refresh either list, edit its
file, update its `source` line with the date checked, and regenerate. The
generator stops with an error if AtlasLoot ever lists Herbalism or Skinning
itself.

`crafts.json` holds the reagents of each Classic recipe, for crafting cost
estimates. Only the addon uses it, as `addon/Goldbook/CraftData.lua`. The
server does not read it. Each recipe has its `spell` ID, the `item` it makes,
its `profession`, the `skill` level needed to learn it, the number of items one
craft `makes`, and its `reagents` as item ID and count pairs in the source's
order. `makes` is 1 when the source gives no number. Recipes that make no
item, such as most enchants, are left out. The recipes come from the same
`Data/Profession.lua` rows as `professions.json`, and the file records that
source's SHA-256 hash.

Refresh both JSON catalogs and both Lua files from a local AtlasLoot snapshot:

```sh
python3 scripts/generate-profession-catalog.py --atlasloot-data "/path/to/AtlasLootClassic/Data"
```

Regenerate all four from the committed JSON and the gathering lists:

```sh
python3 scripts/generate-profession-catalog.py
```

Check that all four match without writing them. The command names the file to
regenerate when one differs:

```sh
python3 scripts/generate-profession-catalog.py --check
```

Verify that both representations agree and exercise the filters through the
addon UI and the real server API:

```sh
cargo build --locked
python3 scripts/verify-professions.py
```
