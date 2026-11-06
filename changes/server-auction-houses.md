- The server can pool WoW Forever realms by auction house. Once the
  maintainer runs it with `GOLDBOOK_AUCTION_HOUSES=forever`, a character on a
  Forever realm that nobody scanned, such as `CAMWOWEU4Realm6PvP`, gets the
  prices scanned on the other realms of its auction house after the app's
  next sync and a `/reload`, and Prices on the website lists each auction
  house once, as `CAMWOWEU4RealmPvP`, instead of each realm. Until then
  nothing changes.
