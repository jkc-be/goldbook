.PHONY: build install-addon rpm install-rpm app run test sandbox dev dev-down dev-logs dev-check check deploy version hooks clean

OVH_HOST ?= fedora_ovh

node_modules: package-lock.json
	npm ci
	@touch node_modules

# Installers for this computer in target/release/bundle: dmg on macOS, setup on Windows, deb and rpm on Linux.
# Then installs this checkout's addon, as install-addon does.
build: node_modules
	npm run desktop:pack
	$(MAKE) install-addon

# Copies this checkout's addon into every game in the World of Warcraft folder,
# keeping each one's ServerData.lua. Another folder: make install-addon WOW=/path.
install-addon:
	cargo run --locked -q -p goldbook-sync -- install --source addon/Goldbook $(if $(WOW),--wow "$(WOW)")

# Linux (Fedora): only the rpm, in target/release/bundle/rpm. Needs rpmbuild.
rpm: node_modules
	npm run desktop:pack -- --bundles rpm

# Build the rpm, then install it with dnf (asks for sudo).
install-rpm: rpm
	f=$$(ls -t target/release/bundle/rpm/*.rpm | head -1); \
	sudo dnf reinstall -y $$f || sudo dnf install -y $$f

# The app without an installer: Goldbook.app on macOS, the bare binary elsewhere. Faster, and needs no rpmbuild on Linux.
app: node_modules
ifeq ($(shell uname -s),Darwin)
	npm run desktop:pack -- --bundles app
else
	npm run desktop:pack -- --no-bundle
endif

run: node_modules
	npm run desktop

# Full local suite, including local Traefik. Needs Docker Compose CLI, not its daemon.
test:
	python3 scripts/test.py

# Use the OVH Compose stack for local development and browser testing.
dev sandbox:
	python3 scripts/dev.py up

dev-down:
	python3 scripts/dev.py down

dev-logs:
	python3 scripts/dev.py logs

dev-check:
	python3 scripts/dev.py check

# The Check workflow and pre-push hook use the same suite.
check:
	python3 scripts/test.py --check

# Deploys this checkout to OVH: backs up the database, since migrations are not
# rolled back, then builds and starts the server there. Only from a clean main
# that matches origin/main, because the deploy ships the files as they are
# here; FORCE=1 skips that check. Another host: make deploy OVH_HOST=me@host.
deploy:
ifneq ($(FORCE),1)
	@git fetch -q origin main
	@test "$$(git rev-parse --abbrev-ref HEAD)" = main || { echo "Check out main first, or deploy anyway with FORCE=1."; exit 1; }
	@test -z "$$(git status --porcelain --untracked-files=no)" || { echo "Commit or stash your changes first, or deploy anyway with FORCE=1."; exit 1; }
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" || { echo "main is not origin/main. Pull or push first, or deploy anyway with FORCE=1."; exit 1; }
endif
	bash server/backup.sh $(OVH_HOST)
	bash server/deploy.sh $(OVH_HOST)

# Sets the client and addon version everywhere a release reads it, such as
# make version VERSION=0.1.5. Then commit, merge to main and run Release desktop.
version:
	@test -n "$(VERSION)" || { echo "Usage: make version VERSION=0.1.5"; exit 1; }
	python3 scripts/set-version.py $(VERSION)

# Run once per clone: makes git use .githooks, so every push runs make check.
hooks:
	git config core.hooksPath .githooks

clean:
	rm -rf target/release/bundle
