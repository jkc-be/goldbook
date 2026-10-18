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
changes nothing a player or user would notice, such as a refactor, tests or
CI, gets the `no-changes` label instead of a file.

## The changes check

The `changes` check on each pull request enforces four rules. Each failure
names its rule and how to fix it.

- **Change file rule.** A pull request that touches `addon/`, `desktop/`,
  `web/`, `crates/` or `server/` adds a file here, and every file it adds or
  edits here is well formed. The `no-changes` label waives this rule, and
  only this rule.
- **Version rule.** Only a release pull request changes the version: the
  `version` in `desktop/src-tauri/tauri.conf.json`, or any other field that
  `scripts/set-version.py` writes. Other edits to those files, such as a
  dependency in `package.json` or `Cargo.toml`, are fine.
- **Changelog rule.** Only a release pull request edits the version sections of
  `CHANGELOG.md`. Rewording its introduction is allowed; the introduction holds
  no sections.
- **Release rule.** A release pull request has the `release` label and is
  what `make prepare-release VERSION=x.y.z` produces: every version field
  holds one version, higher than `main`'s; `CHANGELOG.md` has a
  `## <version> - ` section; every change file is deleted; and nothing else
  changes, apart from the prose of the new section. It needs no change file.

To prepare a release, branch from `main`, run
`make prepare-release VERSION=x.y.z`, edit the new section's prose, and open
the pull request with the `release` label.
