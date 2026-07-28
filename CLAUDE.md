# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`no-sleep` is a single-file macOS Bash CLI (`bin/no-sleep`, ~1300 lines) that prevents sleep by
combining two layers with very different lifetimes:

- a **session-scoped** `caffeinate` process, run under a fixed launchd label
  (`com.callmemorgan.no-sleep.caffeinate`), which dies on logout/reboot;
- the **persistent, system-wide** `pmset -a disablesleep` switch, which survives reboots and needs
  sudo.

Because layer two outlives layer one, the tool keeps an **ownership journal** at
`~/.local/state/no-sleep/state.plist` recording whether *it* changed `SleepDisabled` and what the
value was before. Nearly all of the code's complexity exists to keep that journal honest.

A separate, optional **menu bar app** lives in `app/` (`main.swift`, compiled with `swiftc` via
`make build-app`; `make install-app` signs it with the local Developer ID identity (`sign-app`,
hardened runtime + timestamp; `CODESIGN_IDENTITY` overrides the partial-name match), copies
`NoSleep.app` to `~/Applications`, and registers the
`com.callmemorgan.no-sleep.menubar` LaunchAgent). `make notarize-app` submits to Apple's notary
service and staples the ticket, but needs a one-time interactive
`xcrun notarytool store-credentials` first. The app is read-only against the CLI: it polls
`no-sleep status` (exit codes 0/1/2) to pick an SF Symbol icon, and its on/off menu actions launch
Terminal so the CLI's sudo prompt still has a TTY. It has no tests; keep it that simple unless it
grows real logic.

## Commands

```sh
make check       # test -x, bash -n, shellcheck (also runs as a prerequisite of install/test)
make test        # check + the full mocked suite
make install     # install to ~/.local/bin (refuses to run as root)
make uninstall   # runs a verified `no-sleep off` first; aborts on unresolved ownership state
```

`make check` calls `/opt/homebrew/bin/shellcheck` by absolute path — it must be installed.

There is no test filter flag: `tests/test-no-sleep.sh` invokes every `run_test` line at the bottom
of the file unconditionally. To run one case, comment out the other `run_test` lines (do not commit
that), or source the script's helpers manually.

Live verification is deliberately outside the suite because it mutates the machine's real power
state. If you exercise the real binary, always finish with `no-sleep off` and confirm
`pmset -g | grep SleepDisabled` is `0`.

## Architecture

**Layering in `bin/no-sleep`** (top to bottom): absolute binary paths → globals → state
persistence → power-state readers → launchd job management → transaction/rollback → `do_*` command
implementations → arg parsing → `main`.

**Command flow.** `main` dispatches; `on`/`off`/`toggle` run inside `with_operation_lock` (a
subshell holding `lockf -s -t 0` on `~/.local/state/no-sleep/operation.lock`, exiting **75** if
another operation holds it). `status` takes no lock and never prompts for sudo.

**Two-source power reads.** `read_sleep_pair_once` reads the persistent value from `pmset -g` and
the live value from `ioreg`/`IOPMrootDomain`, and succeeds only when they agree.
`read_consistent_sleep_pair` retries; `verify_sleep_disabled` polls until both equal an expected
value. The tool trusts *verified state*, never a command's exit code: `apply_sleep_disabled`
succeeds when verification passes even if `pmset` returned non-zero, and fails when `pmset`
returned zero but nothing changed. Same pattern for launchd (`wait_for_job_mode`,
`wait_for_job_absent`). Every wait goes through `retry_until <attempts> <predicate>`, so the retry
budgets (10 / 20 / 30) are visible at the call sites rather than buried in four separate loops.

**Journal invariants.** `state_fields_are_valid` is the single description of a well-formed record —
phase (`enabling|enabled|disabling`), mode (`system|display`), and the cross-field rule that
`pmset_changed == true` iff `previous_sleep_disabled == 0`. Both `load_state` (which also checks
schema version) and `write_state` call it, so the reader and writer cannot drift apart. Any
violation is *corrupt* (rc 2), which is treated differently from *absent* (rc 1). `write_state`
writes via `plutil` to a temp file and an atomic `mv`. `path_is_safe` enforces the ownership rules
for both state paths (dir 700, file 600, neither a symlink) and shares the same 0/1/2 convention;
anything unsafe fails closed rather than being repaired.

**Transactions.** `do_on` snapshots the prior job and pmset value (`TX_*` globals) before mutating,
then `rollback_enable` restores pmset, restores or removes the launchd job, and rewrites/removes
the journal if any step fails. A partial rollback warns and deliberately *retains* the journal for
recovery.

**Identity checks before destruction.** `inspect_job` parses `launchctl list` for the label,
program, and exact argv, then cross-checks the PID's uid and full command via `ps`. The allowed
command lines live in `CAFFEINATE_ARGV_SYSTEM` / `CAFFEINATE_ARGV_DISPLAY` — `launchctl_submit_job`
must keep spelling the same flags in the same order, or every job it starts reads back as invalid.
The tool never uses `pkill`/`killall` or name matching, and refuses to
remove a job occupying its label that doesn't match. Correspondingly, an unrecognized job blocks
launchd changes but does **not** block pmset restoration — `do_off` still restores the power
setting and returns 2 with a warning.

**Exit codes.** `status`: 0 on, 1 off, 2 degraded/unknown. Mutating commands: 0 success, 1
precondition/authorization/local failure, 2 transition failed or completed partially, 64 usage, 75
lock contention.

## Conventions

- Bash 3.2 compatible (system `/bin/bash`). No arrays-as-maps, no `${var,,}`, no `mapfile`.
- `set -e` is intentionally **not** used — many probes return non-zero by design and failures must
  reach explicit recovery paths. `set -u` and `pipefail` are on. Check `$?` or use `if !`.
- All external tools are invoked through absolute-path variables (`$PMSET_BIN`, `$LAUNCHCTL_BIN`, …)
  defined at the top. Add new tools the same way and to the `preflight` availability loop.
- Every side effect goes through a small, single-purpose seam function (`sudo_write_sleep_disabled`,
  `launchctl_submit_job`, `read_persistent_sleep_disabled`, `ps_job_line`, `retry_pause`, `now_utc`,
  `state_dir`, …). **This is the testing contract**: `tests/test-no-sleep.sh` sources `bin/no-sleep`
  and redefines exactly these functions to hit a temp-dir fake filesystem. New side effects need a
  seam, or they become untestable and will touch the real machine during `make test`.
- `bin/no-sleep` only runs `main` when executed directly (`BASH_SOURCE[0] == $0`), which is what
  makes sourcing it from the tests safe.
- Output style: `say` for stdout, `warn`/`fail` for stderr with a `no-sleep:` prefix; lowercase
  messages that name the recovery command when one exists.

## Testing notes

Each case runs in a fresh `mktemp -d` root with `set -e` inside a subshell; assertion helpers
(`assert_status`, `assert_contains`, `assert_state_value`, …) return non-zero to fail. Failure
injection works by touching flag files under `$TEST_ROOT/fake` (`fake_set_flag`): e.g.
`pmset_false_success`, `submit_fail`, `remove_fail`, `job_foreign`, `drift_after_remove`,
`authorize_fail`. Prefer adding a flag over adding a new mocking mechanism.

Behaviors worth keeping covered when changing the transition logic: a pre-existing
`SleepDisabled=1` is preserved on `off` (and even on `off --force`); a foreign job at the label is
never removed; corrupt or unowned state requires `--force`; disagreeing power sources fail closed.
