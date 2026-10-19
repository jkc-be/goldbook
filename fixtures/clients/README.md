# Client fixtures

The server deploys before clients update, and players can skip releases. So the
server must keep answering every released client it still supports. Each folder
here holds the requests one released version of the desktop app sends, named by
that version. The oldest folder is the support floor: the server must stay
compatible with that version and every version after it.

`scripts/verify-client-compatibility.py` starts the current server on
disposable databases and replays every folder. It checks the status, headers
and response fields that the released app reads. `make check` runs it. A
failure names the version and the request file.

The addon never talks to the server. The app reads its SavedVariables and
uploads them, so the scan, seller and account requests carry each shape of
`GoldbookDB` that reaches the server. The website is built into the server and
deploys with it, so it needs no fixtures.

## Request files

A folder holds one JSON file per request, replayed in name order against one
server that signs in with Battle.net, as production does. Each file has these
fields.

- `about`: what the app does when it sends the request.
- `source`: where the app sends it, as `file:line` at that version's tag.
- `files`: files to put in the server's data folder first, such as the update
  feed in `updates/`. Optional.
- `request`: `method`, `path`, `headers`, and the body as `body` (text, sent as
  it is) or `json` (a value, sent as JSON).
- `expect`: what the released app needs from the answer.
  - `status`: a status code, a class such as `"2xx"`, or a list of them.
  - `maxBytes`: the largest answer the app reads.
  - `headers`: each value is a regular expression the whole header must match.
  - `body`: the shape of the JSON answer, described below.
- `capture`: response fields to keep for later requests in the folder, as
  `{"name": "field"}`. A later request uses one as `{{name}}`. `{{base}}` is
  the server's address, and `{{battlenet_session}}` a Battle.net session as the
  app holds one after sign-in. The test server cannot reach Battle.net, so the
  session is written into its database.

A shape is a type name (`string`, `boolean`, `null`, `unsigned`, or
`positive`), several joined with `|`, or `{"$match": "<regular expression>"}`
for text. An object lists the keys the app reads, and the server may send
others. A key ending in `?` may be missing, and `*` stands for every key of an
object that must not be empty. A list with one shape matches each entry. A
list with several is a tuple of exactly that length.

All data is synthetic. Character names, realms, IDs and keys come from the
addon tests and are not real players.

## Adding a version

When a release changes a request the app sends, or adds one, copy the newest
folder to one named by the new version and change the files to match what the
new app sends. Leave older folders as they are: they describe apps that players
still run. A release whose requests did not change needs no folder.

## Raising the floor

Raising the floor means deleting the oldest folder, in a PR that says why,
such as that players no longer run that version. After that the server may
drop what only that version needed.

The same PR may also drop a way the new floor version talks to the server,
such as a setting it still offers. It lists the mode below, and a fixture in
that version's folder records how the server refuses it, so the app shows an
error rather than failing silently. The server stays compatible with every
other mode the fixtures cover.

| Version | Mode no longer supported | How the server refuses it |
|---|---|---|
| 0.3.0 | An upload token entered in Settings, such as the server's shared `UPLOAD_TOKEN`. Only Battle.net sign-in uploads | 401, which the app shows as "The server refused this app's upload access" (`19-manual-token-refused.json`) |
