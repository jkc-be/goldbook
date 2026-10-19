.DEFAULT_GOAL := help
.PHONY: help build install-addon rpm install-rpm app run test sandbox dev dev-down dev-logs dev-check check deploy version prepare-release release hooks clean reset-local

OVH_HOST ?= fedora_ovh

# Help requests omit all operational recipes and prerequisites, even with -j.
HELP_REQUESTED := $(filter help help-%,$(MAKECMDGOALS)) $(filter 1,$(HELP))
export GOLDBOOK_HELP_TARGETS := $(filter-out help help-%,$(MAKECMDGOALS)) $(patsubst help-%,%,$(filter help-%,$(MAKECMDGOALS)))

#| Usage: make help [target ...]
#| Examples: make help release; make help build install-addon
#| Also accepted: make help-release; make release help; make release HELP=1
#| Help mode only prints guidance. It skips every requested command and prerequisite.
#| Make owns --help: make release --help displays Make's help, not release guidance.
help: ## Show available commands or detailed help for a command
	@python3 scripts/make-help.py

ifneq ($(strip $(HELP_REQUESTED)),)
.PHONY: $(MAKECMDGOALS)
$(filter-out help,$(MAKECMDGOALS)): help
	@:
else

node_modules: package-lock.json
	npm ci
	@touch node_modules

# Installers for this computer in target/release/bundle: dmg on macOS, setup on Windows, deb and rpm on Linux.
# Then installs this checkout's addon, as install-addon does.
#| Usage: make build [WOW="/path/to/World of Warcraft"]
#| Builds installers for this computer in target/release/bundle, then installs
#| this checkout's addon in detected WoW games. Keeps each ServerData.lua.
#| Needs Node/npm, Rust and the platform's Tauri build dependencies.
#| Example: make build WOW="/Applications/World of Warcraft"
#| Related: make help app; make help install-addon
build: node_modules ## Build installers for this computer and install the addon
	npm run desktop:pack
	$(MAKE) install-addon

# Copies this checkout's addon into every game in the World of Warcraft folder,
# keeping each one's ServerData.lua. Another folder: make install-addon WOW=/path.
#| Usage: make install-addon [WOW="/path/to/World of Warcraft"]
#| Copies addon/Goldbook into every detected WoW game, keeping ServerData.lua.
#| WOW selects a WoW folder instead of automatic discovery. Needs Rust/Cargo.
#| Example: make install-addon WOW="/Applications/World of Warcraft"
#| Reload the game UI after installation.
install-addon: ## Install the addon in every detected WoW game
	cargo run --locked -q -p goldbook-sync -- install --source addon/Goldbook $(if $(WOW),--wow "$(WOW)")

# Linux (Fedora): only the rpm, in target/release/bundle/rpm. Needs rpmbuild.
#| Usage: make rpm
#| Builds a Fedora RPM in target/release/bundle/rpm without installing it.
#| Needs Node/npm, Rust, rpmbuild and the Linux Tauri build dependencies.
#| Related: make help install-rpm
rpm: node_modules ## Build a Fedora RPM installer
	npm run desktop:pack -- --bundles rpm

# Build the rpm, then install it with dnf (asks for sudo).
#| Usage: make install-rpm
#| Builds an RPM, then reinstalls or installs it with dnf and sudo.
#| Needs Fedora's dnf, sudo, rpmbuild, Node/npm and Rust.
#| Related: make help rpm
install-rpm: rpm ## Build and install the RPM with sudo
	f=$$(ls -t target/release/bundle/rpm/*.rpm | head -1); \
	sudo dnf reinstall -y $$f || sudo dnf install -y $$f

# The app without an installer: Goldbook.app on macOS, the bare binary elsewhere. Faster, and needs no rpmbuild on Linux.
#| Usage: make app
#| Builds Goldbook.app on macOS or the desktop binary on other platforms,
#| without an installer. Output is under target/release.
#| Needs Node/npm, Rust and the platform's Tauri build dependencies.
#| Related: make help build; make help run
app: node_modules ## Build the desktop app without an installer
ifeq ($(shell uname -s),Darwin)
	npm run desktop:pack -- --bundles app
else
	npm run desktop:pack -- --no-bundle
endif

# Starts the local server stack, rebuilt from this checkout when it changed, then
# the desktop app in development mode.
#| Usage: make run
#| Starts and verifies the local server stack, then opens the desktop app in
#| development mode. Local development data persists between runs.
#| Needs Node/npm, Rust, Python 3 and Docker Compose with a running daemon.
#| Related: make help dev; make help dev-down
run: node_modules ## Start the local server stack and desktop app
	$(MAKE) dev
	npm run desktop

# Full local suite, including local Traefik. Needs Docker Compose CLI, not its daemon.
#| Usage: make test
#| Runs addon, Rust, Python and HTTP/SQLite integration tests with disposable
#| local databases and loopback servers. Does not open the desktop app.
#| Needs LuaJIT, Rust, Python 3 and the Docker Compose CLI, but no Docker daemon.
#| Related: make help check
test: ## Run the full local test suite
	python3 scripts/test.py

# Use the OVH Compose stack for local development and browser testing.
#| Usage: make dev
#| Alias: make sandbox
#| Builds, starts and verifies the local Docker Compose server stack.
#| Keeps local development data between runs. Needs Python 3 and Docker Compose
#| with a running daemon. It does not open the desktop app.
#| Related: make help run; make help dev-logs; make help dev-down
dev sandbox: ## Start and verify the local server stack
	python3 scripts/dev.py up

#| Usage: make dev-down
#| Stops the local Docker Compose server stack and keeps its data.
#| Needs Python 3 and Docker Compose with a running daemon.
#| Start it again with make dev.
dev-down: ## Stop the local server stack and keep its data
	python3 scripts/dev.py down

#| Usage: make dev-logs
#| Follows logs from the local server stack. Press Ctrl-C to stop following;
#| the stack keeps running. Needs Python 3 and Docker Compose.
#| Related: make help dev; make help dev-check
dev-logs: ## Follow local server logs
	python3 scripts/dev.py logs

#| Usage: make dev-check
#| Checks the running local server stack. Start it with make dev first.
#| Needs Python 3 and Docker Compose.
#| Related: make help dev-logs
dev-check: ## Verify the running local server stack
	python3 scripts/dev.py check

# The Check workflow and pre-push hook use the same suite.
#| Usage: make check
#| Runs the full local test suite plus Rust formatting checks and clippy.
#| This is the suite used by CI and the pre-push hook.
#| Needs LuaJIT, Rust with rustfmt/clippy, Python 3 and the Docker Compose CLI.
#| Tests use disposable local databases and loopback servers, not production.
#| Related: make help test; make help hooks
check: ## Run tests, Rust formatting checks, and clippy
	python3 scripts/test.py --check

# Deploys this checkout to OVH: backs up the database, since migrations are not
# rolled back, then builds and starts the server there. Only from a clean main
# that matches origin/main, because the deploy ships the files as they are
# here; FORCE=1 skips that check. Another host: make deploy OVH_HOST=me@host.
#| Usage: make deploy [OVH_HOST=<ssh-host>] [FORCE=1]
#| Backs up the database, then builds and starts this checkout's server on OVH.
#| OVH_HOST defaults to fedora_ovh. Needs Git, SSH access and server prerequisites.
#| Requires clean main matching origin/main. FORCE=1 skips those checkout checks.
#| This changes the live server. For the unified release flow, use make release.
#| Example: make deploy OVH_HOST=fedora_ovh
#| Details: docs/releasing.md
deploy: ## Back up the database and deploy to OVH
ifneq ($(FORCE),1)
	@git fetch -q origin main
	@test "$$(git rev-parse --abbrev-ref HEAD)" = main || { echo "Check out main first, or deploy anyway with FORCE=1."; exit 1; }
	@test -z "$$(git status --porcelain --untracked-files=no)" || { echo "Commit or stash your changes first, or deploy anyway with FORCE=1."; exit 1; }
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" || { echo "main is not origin/main. Pull or push first, or deploy anyway with FORCE=1."; exit 1; }
endif
	bash server/backup.sh $(OVH_HOST)
	bash server/deploy.sh $(OVH_HOST)

# Sets the client and addon version everywhere a release reads it, such as
# make version VERSION=0.1.5. A release uses prepare-release instead.
#| Usage: make version VERSION=<major.minor.patch>
#| VERSION is required. Updates client and addon version fields in this checkout.
#| Use only in a release PR. Normally use prepare-release to update the changelog too.
#| Example: make version VERSION=1.2.3
#| Related: make help prepare-release
version: ## Set client and addon versions, requires VERSION
	@test -n "$(VERSION)" || { echo "VERSION is required. See make help version (example: make version VERSION=1.2.3)."; exit 1; }
	python3 scripts/set-version.py $(VERSION)

# Turns the files in changes/ into a CHANGELOG.md section, sets the version and
# deletes the files, such as make prepare-release VERSION=0.2.5. Then edit the
# section's prose and open the release pull request with the release label.
#| Usage: make prepare-release VERSION=<major.minor.patch>
#| VERSION is required and must be higher than the current version.
#| On a branch from main, converts changes/ entries into a CHANGELOG.md section,
#| updates version fields and deletes the consumed change files.
#| Review the prose and open a PR with the release label. Publishes nothing.
#| Example: make prepare-release VERSION=1.2.3
#| Next: merge the release PR, then use make release REVISION=<merge-commit>.
#| Details: docs/releasing.md
prepare-release: ## Turn changes/ into a CHANGELOG.md section and set VERSION
	@test -n "$(VERSION)" || { echo "VERSION is required. See make help prepare-release (example: make prepare-release VERSION=1.2.3)."; exit 1; }
	python3 scripts/prepare-release.py $(VERSION)

# Runs Release build on GitHub as you, through gh, for the current main or for
# a commit of main, such as make release REVISION=1a2b3c4. Then asks whether to
# run Release promote for that build. See docs/releasing.md.
#| Usage: make release [REVISION=<commit-sha>]
#| REVISION is a full or abbreviated commit SHA on main. Without it, uses current main.
#| Use the merged release PR's commit so later change files do not block the build.
#| Needs Python 3 and gh signed in as jkc-be, with network access.
#| Starts and follows Release build on GitHub. Environment approvals are required.
#| After a successful build, asks whether to run Release promote. Answering y
#| ships that build's server, update feed and addon, then tags its commit.
#| Example: make release REVISION=1a2b3c4
#| Prepare first: make help prepare-release
#| Details: docs/releasing.md
release: ## Run Release build on GitHub, then offer Release promote
	python3 scripts/release.py $(if $(REVISION),--revision "$(REVISION)")

# Run once per clone: makes git use .githooks, so every push runs make check.
#| Usage: make hooks
#| Sets this clone's Git core.hooksPath to .githooks.
#| Every push then runs make check. This changes the clone's Git configuration.
#| Run once per clone. Needs Git.
#| Related: make help check
hooks: ## Enable the pre-push checks for this clone
	git config core.hooksPath .githooks

#| Usage: make clean
#| Deletes target/release/bundle, including generated installers.
#| Keeps compiled binaries, source files and installed apps.
#| Build new installers with make build.
clean: ## Remove generated installer bundles
	rm -rf target/release/bundle

# Permanently clears local data and removes the macOS app and its privacy grants.
# Quit Goldbook and WoW first. Preview: make reset-local DRY_RUN=1. Custom game: WOW=/path.
#| Usage: make reset-local [DRY_RUN=1] [WOW="/path/to/World of Warcraft"]
#| Permanently deletes local Goldbook data. On macOS, also removes the app and
#| its privacy permissions. Quit Goldbook, WoW and local servers first.
#| DRY_RUN=1 prints the plan without deleting data. WOW adds a WoW installation.
#| Supports macOS and Linux; needs Python 3.
#| Preview first: make reset-local DRY_RUN=1
#| Example: make reset-local DRY_RUN=1 WOW="/Applications/World of Warcraft"
reset-local: ## Delete local data; remove the macOS app and its privacy permissions
	python3 scripts/reset-local.py $(if $(filter 1,$(DRY_RUN)),--dry-run) $(if $(WOW),--wow "$(WOW)")

endif
