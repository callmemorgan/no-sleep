SHELL := /bin/bash

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
STATE_DIR ?= $(HOME)/.local/state/no-sleep
COMMAND := $(BINDIR)/no-sleep

# $@ names the invoking target, so both recipes get their own message.
REFUSE_ROOT = @if [[ "$${EUID}" -eq 0 ]]; then \
		echo "Run make $@ as your login user, not with sudo." >&2; \
		exit 1; \
	fi

.PHONY: all install uninstall test check build-app sign-app notarize-app install-app uninstall-app

all: check

install: check
	$(REFUSE_ROOT)
	/usr/bin/install -d -m 0755 "$(BINDIR)"
	/usr/bin/install -m 0755 bin/no-sleep "$(COMMAND)"
	@echo "Installed $(COMMAND)"

uninstall:
	$(REFUSE_ROOT)
	@if [[ -x "$(COMMAND)" ]]; then \
		"$(COMMAND)" off; \
	else \
		/bin/bash bin/no-sleep off; \
	fi
	/bin/rm -f "$(COMMAND)"
	@if [[ -d "$(STATE_DIR)" && ! -L "$(STATE_DIR)" ]]; then \
		/bin/rm -f "$(STATE_DIR)/operation.lock"; \
		/bin/rmdir "$(STATE_DIR)" 2>/dev/null || true; \
	fi
	@echo "Removed $(COMMAND)"

SHELLCHECK ?= $(shell command -v shellcheck 2>/dev/null || echo /opt/homebrew/bin/shellcheck)

check:
	/bin/test -x bin/no-sleep
	/bin/bash -n bin/no-sleep
	$(SHELLCHECK) -x -s bash bin/no-sleep tests/test-no-sleep.sh

test: check
	/bin/bash tests/test-no-sleep.sh

# Menu bar companion app (app/main.swift, built locally with swiftc and signed
# with a Developer ID identity; notarization is a separate manual step).
APP_NAME := NoSleep
BUILD_DIR := build
APP_BUILT := $(BUILD_DIR)/$(APP_NAME).app
APP_DIR ?= $(HOME)/Applications
APP_INSTALLED := $(APP_DIR)/$(APP_NAME).app
AGENT_LABEL := com.callmemorgan.no-sleep.menubar
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(AGENT_LABEL).plist
# Partial-name match against `security find-identity -p codesigning`; override
# with a full identity string if several Developer ID certificates exist.
CODESIGN_IDENTITY ?= Developer ID Application

build-app:
	/usr/bin/install -d "$(APP_BUILT)/Contents/MacOS"
	/usr/bin/xcrun swiftc -O -o "$(APP_BUILT)/Contents/MacOS/$(APP_NAME)" app/main.swift
	/usr/bin/install -m 0644 app/Info.plist "$(APP_BUILT)/Contents/Info.plist"
	@echo "Built $(APP_BUILT)"

# Hardened runtime with a secure timestamp, matching what notarization would
# require later. No entitlements: the app spawns only child processes, which
# the hardened runtime permits.
sign-app: build-app
	/usr/bin/codesign --force --sign "$(CODESIGN_IDENTITY)" \
		--options runtime --timestamp "$(APP_BUILT)"
	/usr/bin/codesign --verify --deep --strict --verbose=2 "$(APP_BUILT)"
	@echo "Signed $(APP_BUILT) with $(CODESIGN_IDENTITY)"

# Requires a one-time interactive setup:
#   xcrun notarytool store-credentials "$(NOTARY_PROFILE)"
# which needs an app-specific password from appleid.apple.com.
NOTARY_PROFILE ?= notarytool
APP_ZIP := $(BUILD_DIR)/$(APP_NAME).zip

notarize-app: sign-app
	/usr/bin/ditto -c -k --keepParent "$(APP_BUILT)" "$(APP_ZIP)"
	/usr/bin/xcrun notarytool submit "$(APP_ZIP)" \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	/bin/rm -f "$(APP_ZIP)"
	/usr/bin/xcrun stapler staple "$(APP_BUILT)"
	@echo "Notarized $(APP_BUILT)"

install-app: sign-app
	$(REFUSE_ROOT)
	/usr/bin/install -d -m 0755 "$(APP_DIR)" "$(HOME)/Library/LaunchAgents"
	/usr/bin/ditto "$(APP_BUILT)" "$(APP_INSTALLED)"
	/usr/bin/sed -e "s|__APP_PATH__|$(APP_INSTALLED)/Contents/MacOS/$(APP_NAME)|g" \
		"app/$(AGENT_LABEL).plist" > "$(AGENT_PLIST)"
	-/bin/launchctl bootout "gui/$$(id -u)/$(AGENT_LABEL)"
	/bin/launchctl bootstrap "gui/$$(id -u)" "$(AGENT_PLIST)"
	@echo "Installed $(APP_INSTALLED) and started $(AGENT_LABEL)"

uninstall-app:
	$(REFUSE_ROOT)
	-/bin/launchctl bootout "gui/$$(id -u)/$(AGENT_LABEL)"
	/bin/rm -f "$(AGENT_PLIST)"
	/bin/rm -rf "$(APP_INSTALLED)"
	@echo "Removed $(APP_INSTALLED) and $(AGENT_LABEL)"
