# no-sleep

`no-sleep` is a personal macOS CLI that combines two sleep-prevention layers:

- a user-owned, session-scoped `caffeinate` job;
- the persistent system-wide `pmset disablesleep` switch.

The default mode prevents system sleep while allowing the display to turn off.
An explicit display mode keeps both awake.

## Install

```sh
make install
```

This installs `no-sleep` to `~/.local/bin`, which is already on the local
shell path. Installation itself does not need sudo and does not enable
anything.

## Commands

```text
no-sleep                          # status
no-sleep status
no-sleep on|enable [--display]
no-sleep off|disable [--force]
no-sleep toggle [--display]
no-sleep --help
```

`on` and `off` request an administrator password only when they must change
the system-wide `SleepDisabled` value. `status` never prompts.

`--display` changes the caffeinate assertion from `-i` to `-d -i`. Running
`on` again without the flag returns to system-only mode.

## Menu bar indicator

A small unsigned menu bar app mirrors the state so you can tell at a glance
whether sleep prevention is active:

- filled cup: on;
- outline cup: off;
- warning triangle: degraded (for example, after a logout or reboot).

```sh
make install-app
```

This builds `NoSleep.app` from `app/main.swift` with `swiftc`, copies it to
`~/Applications`, and registers a LaunchAgent so it starts at login. The icon
polls `no-sleep status` every few seconds and never prompts for a password.
The menu's on/off actions open a Terminal window running the CLI, because
transitions can legitimately require a sudo password on a real TTY.

Remove it with:

```sh
make uninstall-app
```

## Lifecycle and recovery

The caffeinate job belongs to the current login session. Logging out or
rebooting ends it. The `pmset` hard switch is persistent and remains enabled
until `no-sleep off`, so the tool retains an ownership journal under
`~/.local/state/no-sleep`.

After a logout or reboot, `no-sleep status` reports `degraded`:

- run `no-sleep on` to restore the session assertion;
- run `no-sleep off` to restore the recorded system setting.

If ownership state is missing or corrupt, ordinary `off` will not guess who
enabled the global setting and returns a degraded result while it remains `1`.
`no-sleep off --force` is the explicit recovery command that sets
`SleepDisabled=0`. A valid recorded baseline of `1` is always preserved, even
when `--force` is supplied.

Status exit codes are:

- `0`: fully on;
- `1`: fully off;
- `2`: degraded, externally controlled, or unknown.

Mutating commands return `0` when the requested transition completes and
non-zero on failure.

## Safety

`pmset disablesleep 1` is a hard, system-wide switch. A Mac can remain awake
with its lid closed, draining its battery or heating up in a bag. Always run
`no-sleep off` when the hard switch is no longer needed.

The tool never uses `pkill`, `killall`, or broad process-name matching. It
manages only its fixed launchd label and restores `pmset` only when its journal
shows that it changed the original value.

## Development

```sh
make test
```

The test suite mocks launchd, sudo, pmset, and IOPM state. Live verification
is intentionally separate because it changes the machine's real power state.

To remove the tool safely:

```sh
make uninstall
```

Uninstall first performs a verified ordinary `off` and aborts rather than
discarding unresolved ownership state.

## License

MIT — see [LICENSE](LICENSE).
