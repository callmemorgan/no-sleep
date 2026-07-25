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

.PHONY: all install uninstall test check

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

check:
	/bin/test -x bin/no-sleep
	/bin/bash -n bin/no-sleep
	/opt/homebrew/bin/shellcheck -x -s bash bin/no-sleep tests/test-no-sleep.sh

test: check
	/bin/bash tests/test-no-sleep.sh
