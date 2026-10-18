.DEFAULT_GOAL := help
.PHONY: help build install-addon rpm install-rpm app run test sandbox dev dev-down dev-logs dev-check check deploy version prepare-release release hooks clean reset-local

OVH_HOST ?= fedora_ovh

help: ## Show available commands and options
	@printf 'Usage: make <target> [VARIABLE=value]\n\n'
	@awk -F ':.*## ' '/^[a-zA-Z_-][a-zA-Z_ -]*:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nOptions:\n  WOW=/path         WoW folder for install-addon or reset-local\n  DRY_RUN=1         Preview reset-local without deleting data\n  VERSION=0.2.5     Version for make version or prepare-release\n  REVISION=sha      Commit of main for make release, default: main\n  OVH_HOST=host     Deployment host, default: fedora_ovh\n  FORCE=1           Skip deploy branch and clean-checkout checks\n'

node_modules: package-lock.json
	npm ci
	@touch node_modules

# Installers for this computer in target/release/bundle: dmg on macOS, setup on Windows, deb and rpm on Linux.
# Then installs this checkout's addon, as install-addon does.
build: node_modules ## Build installers for this computer and install the addon
	npm run desktop:pack
	$(MAKE) install-addon

# Copies this checkout's addon into every game in the World of Warcraft folder,
# keeping each one's ServerData.lua. Another folder: make install-addon WOW=/path.
install-addon: ## Install the addon in every detected WoW game
	cargo run --locked -q -p goldbook-sync -- install --source addon/Goldbook $(if $(WOW),--wow "$(WOW)")

# Linux (Fedora): only the rpm, in target/release/bundle/rpm. Needs rpmbuild.
rpm: node_modules ## Build a Fedora RPM installer
	npm run desktop:pack -- --bundles rpm

# Build the rpm, then install it with dnf (asks for sudo).
install-rpm: rpm ## Build and install the RPM with sudo
	f=$$(ls -t target/release/bundle/rpm/*.rpm | head -1); \
	sudo dnf reinstall -y $$f || sudo dnf install -y $$f

# The app without an installer: Goldbook.app on macOS, the bare binary elsewhere. Faster, and needs no rpmbuild on Linux.
app: node_modules ## Build the desktop app without an installer
ifeq ($(shell uname -s),Darwin)
	npm run desktop:pack -- --bundles app
else
	npm run desktop:pack -- --no-bundle
endif

# Starts the local server stack, rebuilt from this checkout when it changed, then
# the desktop app in development mode.
run: node_modules ## Start the local server stack and desktop app
	$(MAKE) dev
	npm run desktop

# Full local suite, including local Traefik. Needs Docker Compose CLI, not its daemon.
test: ## Run the full local test suite
	python3 scripts/test.py

# Use the OVH Compose stack for local development and browser testing.
dev sandbox: ## Start and verify the local server stack
	python3 scripts/dev.py up

dev-down: ## Stop the local server stack and keep its data
	python3 scripts/dev.py down

dev-logs: ## Follow local server logs
	python3 scripts/dev.py logs

dev-check: ## Verify the running local server stack
	python3 scripts/dev.py check

# The Check workflow and pre-push hook use the same suite.
check: ## Run tests, Rust formatting checks, and clippy
	python3 scripts/test.py --check

# Deploys this checkout to OVH: backs up the database, since migrations are not
# rolled back, then builds and starts the server there. Only from a clean main
# that matches origin/main, because the deploy ships the files as they are
# here; FORCE=1 skips that check. Another host: make deploy OVH_HOST=me@host.
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
version: ## Set client and addon versions, requires VERSION
	@test -n "$(VERSION)" || { echo "Usage: make version VERSION=0.1.5"; exit 1; }
	python3 scripts/set-version.py $(VERSION)

# Turns the files in changes/ into a CHANGELOG.md section, sets the version and
# deletes the files, such as make prepare-release VERSION=0.2.5. Then edit the
# section's prose and open the release pull request with the release label.
prepare-release: ## Turn changes/ into a CHANGELOG.md section and set VERSION
	@test -n "$(VERSION)" || { echo "Usage: make prepare-release VERSION=0.2.5"; exit 1; }
	python3 scripts/prepare-release.py $(VERSION)

# Runs Release build on GitHub as you, through gh, for the current main or for
# a commit of main, such as make release REVISION=1a2b3c4. Then asks whether to
# run Release promote for that build. See docs/releasing.md.
release: ## Run Release build on GitHub, then offer Release promote
	python3 scripts/release.py $(if $(REVISION),--revision "$(REVISION)")

# Run once per clone: makes git use .githooks, so every push runs make check.
hooks: ## Enable the pre-push checks for this clone
	git config core.hooksPath .githooks

clean: ## Remove generated installer bundles
	rm -rf target/release/bundle

# Permanently clears local data and removes the macOS app and its privacy grants.
# Quit Goldbook and WoW first. Preview: make reset-local DRY_RUN=1. Custom game: WOW=/path.
reset-local: ## Delete local data; remove the macOS app and its privacy permissions
	python3 scripts/reset-local.py $(if $(filter 1,$(DRY_RUN)),--dry-run) $(if $(WOW),--wow "$(WOW)")
