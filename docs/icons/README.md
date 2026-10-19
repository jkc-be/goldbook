# Rail icons

The icons of the addon's, the website's and the app's rail, and the drawings
kept for later. Each is a few straight strokes in a 16 by 16 box, y growing
downward, drawn 1.5 wide.

The addon draws them with line textures, and the game client leaves out lines
much shorter than 4, so no stroke is shorter than 4 and curves are a few long
strokes. `addon/tests/run.lua` checks the icons in use.

To use one, copy its strokes into `GLYPHS` in `addon/Goldbook/UI.lua` and its
paths into the hub's `icon` in `web/app.js` and in `desktop/ui/index.html`.

| | Name | Use | Addon strokes | Web paths |
| --- | --- | --- | --- | --- |
| <img src="chart.svg" width="32" alt=""> | `chart` | Market | `{ { 2, 2, 2, 14, 14, 14 }, { 4, 11, 7, 6, 10, 9, 14, 3 } }` | `["M2 2 L2 14 L14 14", "M4 11 L7 6 L10 9 L14 3"]` |
| <img src="chest.svg" width="32" alt=""> | `chest` | Inventory | `{ { 2, 7, 14, 7, 14, 14, 2, 14, 2, 7 }, { 2, 7, 4, 2.5, 12, 2.5, 14, 7 }, { 8, 7, 8, 11 } }` | `["M2 7 L14 7 L14 14 L2 14Z", "M2 7 L4 2.5 L12 2.5 L14 7", "M8 7 L8 11"]` |
| <img src="scales.svg" width="32" alt=""> | `scales` | Ledger | `{ { 8, 2, 8, 14 }, { 3, 5, 13, 5 }, { 3, 5, 1, 10, 5, 10, 3, 5 }, { 13, 5, 11, 10, 15, 10, 13, 5 } }` | `["M8 2 L8 14", "M3 5 L13 5", "M3 5 L1 10 L5 10Z", "M13 5 L11 10 L15 10Z"]` |
| <img src="tag.svg" width="32" alt=""> | `tag` | Market until this change | `{ { 2, 8, 8, 2, 14, 2, 14, 8, 8, 14, 2, 8 } }` | `["M2 8 L8 2 L14 2 L14 8 L8 14Z"]` |
| <img src="bag.svg" width="32" alt=""> | `bag` | Inventory until this change | `{ { 3, 5, 13, 5, 12, 14, 4, 14, 3, 5 }, { 4.5, 5, 5.5, 0.8, 10.5, 0.8, 11.5, 5 } }` | `["M3 5 L13 5 L12 14 L4 14Z", "M4.5 5 L5.5 0.8 L10.5 0.8 L11.5 5"]` |
| <img src="stall.svg" width="32" alt=""> | `stall` | Unused: a market stall | `{ { 1, 6, 3, 2, 13, 2, 15, 6, 1, 6 }, { 3, 6, 3, 14 }, { 13, 6, 13, 14 }, { 3, 10, 13, 10 } }` | `["M1 6 L3 2 L13 2 L15 6Z", "M3 6 L3 14", "M13 6 L13 14", "M3 10 L13 10"]` |
| <img src="gavel.svg" width="32" alt=""> | `gavel` | Unused: an auction gavel | `{ { 2.5, 6.5, 6.5, 2.5, 9.5, 5.5, 5.5, 9.5, 2.5, 6.5 }, { 8, 8, 14, 14 }, { 1, 14, 8, 14 } }` | `["M2.5 6.5 L6.5 2.5 L9.5 5.5 L5.5 9.5Z", "M8 8 L14 14", "M1 14 L8 14"]` |
| <img src="pouch.svg" width="32" alt=""> | `pouch` | Unused: a pouch | `{ { 4, 6, 12, 6, 14, 14, 2, 14, 4, 6 }, { 6, 6, 8, 2, 10, 6 } }` | `["M4 6 L12 6 L14 14 L2 14Z", "M6 6 L8 2 L10 6"]` |
| <img src="backpack.svg" width="32" alt=""> | `backpack` | Unused: a backpack | `{ { 3, 5, 13, 5, 13, 15, 3, 15, 3, 5 }, { 6, 5, 6, 1, 10, 1, 10, 5 }, { 3, 10, 13, 10 } }` | `["M3 5 L13 5 L13 15 L3 15Z", "M6 5 L6 1 L10 1 L10 5", "M3 10 L13 10"]` |
