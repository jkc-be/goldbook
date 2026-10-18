# Unreleased changes

Each pull request that a player or user would notice adds one file here. The
release pull request runs `make prepare-release VERSION=x.y.z`, which turns
these files into a section of [CHANGELOG.md](../CHANGELOG.md), sets the
version and deletes them. Pull requests never edit `CHANGELOG.md` themselves.

Name the file `<section>-<slug>.md`, such as `addon-mail-collect.md`. The
slug is lowercase letters, digits and hyphens. The section is one of these,
and decides the changelog heading the entry goes under:

| Section | Heading | For changes to |
| --- | --- | --- |
| `addon` | Addon | the in-game addon |
| `app` | Desktop app | the desktop app and the terminal sync |
| `website` | Website | the browser UI |
| `server` | Server | the API server, its data and its deployment |
| `build` | Build | building, testing and releasing |

The body is one or more Markdown bullets, written for the player as the
existing changelog is: say what changed and what they see, in plain sentences,
with commands and names in backticks and buttons in bold. Wrap lines at about
78 characters and indent continuation lines by two spaces.

```markdown
- Add a Mail view, beside Bags under Inventory, that opens with the mailbox.
  `/gb mail` opens it; an Options tick keeps it from opening by itself.
```

Within a heading, entries are ordered by file name. A pull request that
changes nothing a player or user would notice, such as a refactor, tests, CI
or a release, gets the `no-changes` label instead of a file. The `changes`
check fails when a pull request touches `addon/`, `desktop/`, `web/`,
`crates/` or `server/` without adding a file here and without that label.
