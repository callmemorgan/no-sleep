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

.PHONY: all install uninstall test check build-app install-app uninstall-app

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

# Menu bar companion app (app/main.swift, unsigned, built locally with swiftc).
APP_NAME := NoSleep
BUILD_DIR := build
APP_BUILT := $(BUILD_DIR)/$(APP_NAME).app
APP_DIR ?= $(HOME)/Applications
APP_INSTALLED := $(APP_DIR)/$(APP_NAME).app
AGENT_LABEL := com.callmemorgan.no-sleep.menubar
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(AGENT_LABEL).plist

build-app:
	/usr/bin/install -d "$(APP_BUILT)/Contents/MacOS"
	/usr/bin/xcrun swiftc -O -o "$(APP_BUILT)/Contents/MacOS/$(APP_NAME)" app/main.swift
	/usr/bin/install -m 0644 app/Info.plist "$(APP_BUILT)/Contents/Info.plist"
	@echo "Built $(APP_BUILT)"

install-app: build-app
	$(REFUSE_ROOT)
	/usr/bin/install -d -m 0755 "$(APP_DIR)" "$(HOME)/Library/LaunchAgents"
	/usr/bin/ditto "$(APP_BUILT)" "$(APP_INSTALLED)"
	/usr/bin/sed -e "s|__HOME__|$(HOME)|g" "app/$(AGENT_LABEL).plist" > "$(AGENT_PLIST)"
	-/bin/launchctl bootout "gui/$$(id -u)/$(AGENT_LABEL)"
	/bin/launchctl bootstrap "gui/$$(id -u)" "$(AGENT_PLIST)"
	@echo "Installed $(APP_INSTALLED) and started $(AGENT_LABEL)"

uninstall-app:
	$(REFUSE_ROOT)
	-/bin/launchctl bootout "gui/$$(id -u)/$(AGENT_LABEL)"
	/bin/rm -f "$(AGENT_PLIST)"
	/bin/rm -rf "$(APP_INSTALLED)"
	@echo "Removed $(APP_INSTALLED) and $(AGENT_LABEL)"
