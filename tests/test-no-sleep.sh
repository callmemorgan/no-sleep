#!/bin/bash

set -u
set -o pipefail
umask 077

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=bin/no-sleep
source "${PROJECT_ROOT}/bin/no-sleep"

TEST_ROOT=""
COMMAND_OUTPUT=""
COMMAND_STATUS="0"
TESTS_RUN="0"
TESTS_FAILED="0"

state_dir() {
    printf '%s/state\n' "$TEST_ROOT"
}

retry_pause() {
    :
}

now_utc() {
    printf '2026-07-24T20:00:00Z\n'
}

fake_path() {
    printf '%s/fake/%s\n' "$TEST_ROOT" "$1"
}

fake_read() {
    local name

    name="$1"
    /bin/cat "$(fake_path "$name")"
}

fake_write() {
    local name
    local value

    name="$1"
    value="$2"
    printf '%s\n' "$value" >"$(fake_path "$name")"
}

fake_flag() {
    [[ -e "$(fake_path "$1")" ]]
}

fake_set_flag() {
    : >"$(fake_path "$1")"
}

fake_clear_flag() {
    /bin/rm -f "$(fake_path "$1")"
}

fake_set_job() {
    local mode

    mode="$1"
    fake_write "job_present" "1"
    fake_write "job_mode" "$mode"
    fake_write "job_pid" "4242"
}

fake_clear_job() {
    /bin/rm -f \
        "$(fake_path "job_present")" \
        "$(fake_path "job_mode")" \
        "$(fake_path "job_pid")"
}

read_persistent_sleep_disabled() {
    fake_read "persistent"
}

read_live_sleep_disabled() {
    fake_read "live"
}

sudo_authorize() {
    printf 'authorize\n' >>"$(fake_path "sudo.log")"
    if fake_flag "authorize_fail"; then
        return 1
    fi
    return 0
}

sudo_write_sleep_disabled() {
    local value

    value="$1"
    printf '%s\n' "$value" >>"$(fake_path "pmset.log")"
    if fake_flag "pmset_fail"; then
        return 1
    fi
    if fake_flag "pmset_false_success"; then
        return 0
    fi
    fake_write "persistent" "$value"
    fake_write "live" "$value"
    if fake_flag "pmset_nonzero_after_change"; then
        return 1
    fi
    return 0
}

launchctl_list_job() {
    local mode
    local pid
    local program

    if ! fake_flag "job_present"; then
        return 113
    fi
    mode=$(fake_read "job_mode")
    pid=$(fake_read "job_pid")
    program="$CAFFEINATE_BIN"
    if fake_flag "job_foreign"; then
        program="/usr/bin/yes"
    fi

    printf '{\n'
    printf '\t"Label" = "%s";\n' "$JOB_LABEL"
    if ! fake_flag "job_no_pid"; then
        printf '\t"PID" = %s;\n' "$pid"
    fi
    printf '\t"Program" = "%s";\n' "$program"
    printf '\t"ProgramArguments" = (\n'
    printf '\t\t"%s";\n' "$program"
    if [[ "$mode" == "display" ]]; then
        printf '\t\t"-d";\n'
    fi
    printf '\t\t"-i";\n'
    printf '\t);\n'
    printf '};\n'
}

ps_job_line() {
    local pid
    local mode

    pid="$1"
    mode=$(fake_read "job_mode")
    if fake_flag "ps_missing"; then
        return 1
    fi
    if [[ "$mode" == "display" ]]; then
        printf '%s %s -d -i\n' "$(current_uid)" "$CAFFEINATE_BIN"
    else
        printf '%s %s -i\n' "$(current_uid)" "$CAFFEINATE_BIN"
    fi
    [[ "$pid" == "$(fake_read "job_pid")" ]]
}

launchctl_submit_job() {
    local mode

    mode="$1"
    printf 'submit %s\n' "$mode" >>"$(fake_path "launchctl.log")"
    if fake_flag "submit_fail"; then
        return 1
    fi
    fake_set_job "$mode"
    if fake_flag "submit_nonzero_after_start"; then
        return 1
    fi
}

launchctl_remove_job() {
    printf 'remove\n' >>"$(fake_path "launchctl.log")"
    if fake_flag "remove_fail"; then
        return 1
    fi
    fake_clear_job
    if fake_flag "drift_after_remove"; then
        fake_write "persistent" "1"
        fake_write "live" "1"
    fi
}

setup_case() {
    /bin/mkdir -p "$TEST_ROOT/fake"
    fake_write "persistent" "0"
    fake_write "live" "0"
    : >"$(fake_path "sudo.log")"
    : >"$(fake_path "pmset.log")"
    : >"$(fake_path "launchctl.log")"
}

run_command() {
    set +e
    COMMAND_OUTPUT=$(main "$@" 2>&1)
    COMMAND_STATUS=$?
    set -e
    return 0
}

run_direct() {
    set +e
    COMMAND_OUTPUT=$("$@" 2>&1)
    COMMAND_STATUS=$?
    set -e
    return 0
}

assert_status() {
    local expected

    expected="$1"
    if [[ "$COMMAND_STATUS" -ne "$expected" ]]; then
        printf 'expected status %s, got %s\noutput:\n%s\n' \
            "$expected" "$COMMAND_STATUS" "$COMMAND_OUTPUT" >&2
        return 1
    fi
}

assert_contains() {
    local needle

    needle="$1"
    if [[ "$COMMAND_OUTPUT" != *"$needle"* ]]; then
        printf 'expected output to contain %q\noutput:\n%s\n' \
            "$needle" "$COMMAND_OUTPUT" >&2
        return 1
    fi
}

assert_file_value() {
    local path
    local expected
    local actual

    path="$1"
    expected="$2"
    actual=$(/bin/cat "$path") || return 1
    if [[ "$actual" != "$expected" ]]; then
        printf 'expected %s to contain %q, got %q\n' \
            "$path" "$expected" "$actual" >&2
        return 1
    fi
}

assert_file_absent() {
    local path

    path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        printf 'expected path to be absent: %s\n' "$path" >&2
        return 1
    fi
}

assert_state_value() {
    local key
    local expected
    local actual
    local expected_type

    key="$1"
    expected="$2"
    case "$key" in
        schema_version|previous_sleep_disabled) expected_type="integer" ;;
        pmset_changed) expected_type="bool" ;;
        *) expected_type="string" ;;
    esac
    actual=$(plist_extract "$key" "$expected_type" "$(state_file)") || return 1
    if [[ "$actual" != "$expected" ]]; then
        printf 'expected state %s=%q, got %q\n' "$key" "$expected" "$actual" >&2
        return 1
    fi
}

test_status_help_and_usage() {
    run_command
    assert_status 1
    assert_contains "no-sleep: off"

    run_command --help
    assert_status 0
    assert_contains "Usage:"

    run_command help
    assert_status 0
    assert_contains "Usage:"

    run_command -h
    assert_status 0
    assert_contains "Usage:"

    run_command --version
    assert_status 0
    assert_contains "no-sleep 0.1.0"

    run_command version
    assert_status 0
    assert_contains "no-sleep 0.1.0"

    run_command nonsense
    assert_status 64
    assert_contains "unknown command"

    run_command on --wat
    assert_status 64
    assert_contains "expected no option or --display"
}

test_power_parser_contracts() {
    local actual

    actual=$(printf '%s\n' \
        "System-wide power settings:" \
        " SleepDisabled        1" \
        "Currently in use:" | parse_persistent_sleep_disabled)
    [[ "$actual" == "1" ]]

    actual=$(printf '%s\n' \
        "System-wide power settings:" \
        " SleepDisabled        0" \
        "Currently in use:" | parse_persistent_sleep_disabled)
    [[ "$actual" == "0" ]]

    actual=$(printf '%s\n' \
        "System-wide power settings:" \
        "Currently in use:" | parse_persistent_sleep_disabled)
    [[ "$actual" == "0" ]]

    if printf '%s\n' \
        "System-wide power settings:" \
        " SleepDisabled 0" \
        " SleepDisabled 1" \
        "Currently in use:" | parse_persistent_sleep_disabled >/dev/null 2>&1; then
        printf 'duplicate SleepDisabled values should fail parsing\n' >&2
        return 1
    fi

    if actual=$(printf '%s\n' \
        "System-wide power settings:" \
        " SleepDisabled 2" \
        "Currently in use:" | parse_persistent_sleep_disabled); then
        printf 'invalid SleepDisabled value should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]

    if actual=$(printf '%s\n' \
        "System-wide power settings:" \
        " SleepDisabled 1 unexpected" \
        "Currently in use:" | parse_persistent_sleep_disabled); then
        printf 'malformed SleepDisabled fields should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]

    if actual=$(printf '%s\n' \
        "System-wide power settings:" \
        " SleepDisabled 1" | parse_persistent_sleep_disabled); then
        printf 'truncated pmset output should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]

    if actual=$(printf '%s\n' \
        "Currently in use:" | parse_persistent_sleep_disabled); then
        printf 'pmset output without the system header should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]

    if actual=$(printf '%s\n' \
        "Currently in use:" \
        "System-wide power settings:" | parse_persistent_sleep_disabled); then
        printf 'reordered pmset headers should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]

    if actual=$(printf '%s\n' \
        "System-wide power settings:" \
        "Currently in use:" \
        " SleepDisabled 1" | parse_persistent_sleep_disabled); then
        printf 'misplaced SleepDisabled should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]

    if actual=$(printf '' | parse_persistent_sleep_disabled); then
        printf 'empty pmset output should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]

    actual=$(printf '%s\n' '[{}]' | parse_live_sleep_disabled)
    [[ "$actual" == "0" ]]

    actual=$(printf '%s\n' '[{"SleepDisabled":true}]' | parse_live_sleep_disabled)
    [[ "$actual" == "1" ]]

    actual=$(printf '%s\n' '[{"SleepDisabled":false}]' | parse_live_sleep_disabled)
    [[ "$actual" == "0" ]]

    if actual=$(printf '' | parse_live_sleep_disabled); then
        printf 'empty ioreg output should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]

    if actual=$(printf '%s\n' 'not a plist' | parse_live_sleep_disabled); then
        printf 'malformed ioreg plist should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]

    if actual=$(printf '%s\n' '{}' | parse_live_sleep_disabled); then
        printf 'non-array ioreg root should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]

    if actual=$(printf '%s\n' '["unexpected"]' | parse_live_sleep_disabled); then
        printf 'non-dictionary root-domain entry should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]

    if actual=$(printf '%s\n' '[{},{}]' | parse_live_sleep_disabled); then
        printf 'multiple root-domain entries should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]

    if actual=$(printf '%s\n' '[{"SleepDisabled":1}]' | parse_live_sleep_disabled); then
        printf 'non-Boolean live SleepDisabled should fail parsing\n' >&2
        return 1
    fi
    [[ -z "$actual" ]]
}

test_privileged_command_contract() {
    local original_sudo
    local capture
    local fake_sudo

    original_sudo="$SUDO_BIN"
    capture="$(fake_path "sudo-argv.log")"
    fake_sudo="$(fake_path "sudo-command")"
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/bin/bash' \
        'printf "%s\n" "$@" >"$NO_SLEEP_TEST_SUDO_CAPTURE"' >"$fake_sudo"
    /bin/chmod 700 "$fake_sudo"
    export NO_SLEEP_TEST_SUDO_CAPTURE="$capture"
    SUDO_BIN="$fake_sudo"

    # Without SUDO_ASKPASS there is no -A, whether or not stdin is a terminal.
    ( unset SUDO_ASKPASS; invoke_sudo_pmset "1" )
    assert_file_value "$capture" "$(printf '%s\n' \
        "--" "$PMSET_BIN" "-a" "disablesleep" "1")"

    # With SUDO_ASKPASS set and no TTY on stdin (the menu bar app's case),
    # sudo is asked to use the askpass helper instead of prompting.
    : >"$capture"
    ( SUDO_ASKPASS="$(fake_path "askpass")"; export SUDO_ASKPASS; invoke_sudo_pmset "1" ) </dev/null
    assert_file_value "$capture" "$(printf '%s\n' \
        "-A" "--" "$PMSET_BIN" "-a" "disablesleep" "1")"

    : >"$capture"
    if ( unset SUDO_ASKPASS; invoke_sudo_pmset "invalid" ); then
        printf 'invalid pmset value should be rejected\n' >&2
        return 1
    fi
    assert_file_value "$capture" ""

    SUDO_BIN="$original_sudo"
    unset NO_SLEEP_TEST_SUDO_CAPTURE
}

test_fresh_on_off_idempotent() {
    run_command on
    assert_status 0
    assert_contains "no-sleep: on (system only)"
    assert_file_value "$(fake_path "persistent")" "1"
    assert_file_value "$(fake_path "live")" "1"
    assert_file_value "$(fake_path "job_mode")" "system"
    assert_state_value "phase" "enabled"
    assert_state_value "previous_sleep_disabled" "0"
    assert_state_value "pmset_changed" "true"
    assert_file_value "$(fake_path "pmset.log")" "1"

    run_command on
    assert_status 0
    assert_file_value "$(fake_path "pmset.log")" "1"

    run_command status
    assert_status 0
    assert_contains "caffeinate: running"

    run_command off
    assert_status 0
    assert_contains "SleepDisabled: 0"
    assert_file_value "$(fake_path "persistent")" "0"
    assert_file_absent "$(fake_path "job_present")"
    assert_file_absent "$(state_file)"

    run_command off
    assert_status 0
}

test_preserves_preexisting_pmset() {
    fake_write "persistent" "1"
    fake_write "live" "1"

    run_command enable
    assert_status 0
    assert_state_value "previous_sleep_disabled" "1"
    assert_state_value "pmset_changed" "false"
    assert_file_value "$(fake_path "pmset.log")" ""

    run_command disable
    assert_status 0
    assert_file_value "$(fake_path "persistent")" "1"
    assert_file_value "$(fake_path "pmset.log")" ""

    run_command status
    assert_status 2
    assert_contains "unowned"
}

test_force_preserves_valid_preexisting_baseline() {
    fake_write "persistent" "1"
    fake_write "live" "1"

    run_command on
    assert_status 0

    run_command off --force
    assert_status 0
    assert_file_value "$(fake_path "persistent")" "1"
    assert_file_value "$(fake_path "pmset.log")" ""
}

test_display_mode_reconfiguration() {
    run_command on --display
    assert_status 0
    assert_file_value "$(fake_path "job_mode")" "display"
    assert_state_value "mode" "display"

    run_command on
    assert_status 0
    assert_file_value "$(fake_path "job_mode")" "system"
    assert_state_value "mode" "system"
    assert_file_value "$(fake_path "pmset.log")" "1"

    run_command off
    assert_status 0
}

test_toggle_paths() {
    run_command toggle --display
    assert_status 0
    assert_file_value "$(fake_path "job_mode")" "display"

    run_command toggle
    assert_status 0
    assert_file_value "$(fake_path "persistent")" "0"
    assert_file_absent "$(fake_path "job_present")"
}

test_sudo_cancel_has_no_side_effects() {
    fake_set_flag "authorize_fail"

    run_command on
    assert_status 1
    assert_contains "authorization was not granted"
    assert_file_value "$(fake_path "persistent")" "0"
    assert_file_absent "$(fake_path "job_present")"
    assert_file_absent "$(state_file)"
}

test_pmset_false_success_rolls_back() {
    fake_set_flag "pmset_false_success"

    run_command on
    assert_status 2
    assert_contains "pmset reported success"
    assert_file_value "$(fake_path "persistent")" "0"
    assert_file_absent "$(fake_path "job_present")"
    assert_file_absent "$(state_file)"
}

test_pmset_nonzero_with_verified_change_succeeds() {
    fake_set_flag "pmset_nonzero_after_change"

    run_command on
    assert_status 0
    assert_file_value "$(fake_path "persistent")" "1"

    run_command off
    assert_status 0
    assert_file_value "$(fake_path "persistent")" "0"
}

test_submit_failure_rolls_back() {
    fake_set_flag "submit_fail"

    run_command on
    assert_status 2
    assert_contains "did not start caffeinate"
    assert_file_value "$(fake_path "persistent")" "0"
    assert_file_value "$(fake_path "pmset.log")" ""
    assert_file_absent "$(state_file)"
}

test_submit_nonzero_with_live_job_succeeds() {
    fake_set_flag "submit_nonzero_after_start"

    run_command on
    assert_status 0
    assert_file_value "$(fake_path "job_mode")" "system"

    run_command off
    assert_status 0
}

test_remove_failure_retains_recovery_state() {
    run_command on
    assert_status 0
    fake_set_flag "remove_fail"

    run_command off
    assert_status 2
    assert_contains "could not be removed"
    assert_file_value "$(fake_path "persistent")" "0"
    assert_state_value "phase" "disabling"
    [[ -e "$(fake_path "job_present")" ]]

    fake_clear_flag "remove_fail"
    run_command off
    assert_status 0
    assert_file_absent "$(state_file)"
    assert_file_absent "$(fake_path "job_present")"
}

test_reboot_style_degraded_recovery() {
    run_command on
    assert_status 0
    fake_clear_job

    run_command status
    assert_status 2
    assert_contains "resume this session"

    run_command on --display
    assert_status 0
    assert_file_value "$(fake_path "job_mode")" "display"
    assert_file_value "$(fake_path "pmset.log")" "1"

    run_command off
    assert_status 0
    assert_file_value "$(fake_path "persistent")" "0"
}

test_corrupt_state_requires_force() {
    /bin/mkdir -p "$(state_dir)"
    printf 'not a plist\n' >"$(state_file)"
    /bin/chmod 600 "$(state_file)"
    fake_write "persistent" "1"
    fake_write "live" "1"
    fake_set_job "system"

    run_command off
    assert_status 2
    assert_contains "corrupt ownership state"
    assert_file_value "$(fake_path "persistent")" "1"
    assert_file_absent "$(fake_path "job_present")"
    [[ -f "$(state_file)" ]]

    run_command off --force
    assert_status 0
    assert_file_value "$(fake_path "persistent")" "0"
    assert_file_absent "$(state_file)"
}

test_unowned_global_requires_force() {
    fake_write "persistent" "1"
    fake_write "live" "1"

    run_command off
    assert_status 2
    assert_contains "still 1 with no ownership record"
    assert_file_value "$(fake_path "persistent")" "1"

    run_command off --force
    assert_status 0
    assert_file_value "$(fake_path "persistent")" "0"
}

test_toggle_refuses_unowned_global_state() {
    fake_write "persistent" "1"
    fake_write "live" "1"

    run_command toggle
    assert_status 2
    assert_contains "use 'no-sleep on' to adopt it"
    assert_file_absent "$(fake_path "job_present")"
    assert_file_value "$(fake_path "persistent")" "1"
}

test_foreign_job_is_never_removed() {
    fake_set_job "system"
    fake_set_flag "job_foreign"

    run_command on
    assert_status 2
    assert_contains "unrecognized job"
    [[ -e "$(fake_path "job_present")" ]]

    run_command off --force
    assert_status 2
    assert_contains "unrecognized job"
    [[ -e "$(fake_path "job_present")" ]]
    assert_file_value "$(fake_path "persistent")" "0"
}

test_owned_pmset_restores_despite_foreign_job_shape() {
    run_command on
    assert_status 0
    fake_set_flag "job_foreign"

    run_command off
    assert_status 2
    assert_contains "pmset restoration"
    assert_file_value "$(fake_path "persistent")" "0"
    assert_state_value "phase" "disabling"
    [[ -e "$(fake_path "job_present")" ]]

    fake_clear_flag "job_foreign"
    run_command off
    assert_status 0
    assert_file_absent "$(fake_path "job_present")"
    assert_file_absent "$(state_file)"
}

test_power_drift_after_job_removal_retains_state() {
    run_command on
    assert_status 0
    fake_set_flag "drift_after_remove"

    run_command off
    assert_status 2
    assert_contains "drifted after caffeinate stopped"
    assert_file_value "$(fake_path "persistent")" "1"
    assert_state_value "phase" "disabling"

    fake_clear_flag "drift_after_remove"
    run_command off
    assert_status 0
    assert_file_value "$(fake_path "persistent")" "0"
    assert_file_absent "$(state_file)"
}

test_mismatched_power_sources_fail_closed() {
    fake_write "persistent" "0"
    fake_write "live" "1"

    run_command on
    assert_status 2
    assert_contains "unavailable or disagree"
    assert_file_absent "$(fake_path "job_present")"
    assert_file_absent "$(state_file)"
}

test_unsafe_state_directory_fails_closed() {
    /bin/mkdir -p "$TEST_ROOT/unsafe-target"
    /bin/ln -s "$TEST_ROOT/unsafe-target" "$(state_dir)"

    run_command status
    assert_status 2
    assert_contains "journal: corrupt or unsafe"

    run_command on
    assert_status 1
    assert_contains "state directory is unsafe"
}

test_concurrent_operation_fails_fast() {
    local holder
    local lock

    /bin/mkdir -m 700 "$(state_dir)"
    lock=$(lock_file)
    "$LOCKF_BIN" -k "$lock" "$SLEEP_BIN" 5 &
    holder=$!
    "$SLEEP_BIN" 0.1

    run_command on
    /bin/kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true

    assert_status 75
    assert_contains "already in progress"
    assert_file_absent "$(fake_path "job_present")"
    assert_file_absent "$(state_file)"
}

test_remove_state_dir_safety_guard() {
    /bin/mkdir -p "$TEST_ROOT/unsafe-target"
    /bin/ln -s "$TEST_ROOT/unsafe-target" "$(state_dir)"

    run_direct remove_state
    assert_status 1
    assert_contains "refusing to remove state file from an unsafe directory"
}

test_toggle_refuses_corrupt_state() {
    /bin/mkdir -m 700 "$(state_dir)"
    printf 'corrupt data' > "$(state_file)"
    /bin/chmod 600 "$(state_file)"

    run_command toggle
    assert_status 2
    assert_contains "state journal is corrupt or unsafe"
}

test_forced_recovery_restores_sleep_with_unsafe_state_file() {
    fake_write "persistent" "1"
    fake_write "live" "1"
    /bin/mkdir -m 700 "$(state_dir)"
    printf 'corrupt data' > "$(state_file)"
    /bin/chmod 644 "$(state_file)"

    run_command off --force
    assert_status 2
    assert_contains "corrupt state path could not be removed"
    assert_file_value "$(fake_path "persistent")" "0"
    assert_file_value "$(fake_path "live")" "0"
}

test_external_baseline_invalidation_drift() {
    fake_write "persistent" "1"
    fake_write "live" "1"

    run_command on
    assert_status 0
    assert_contains "pre-existing; will be preserved on off"
    assert_state_value "pmset_changed" "false"

    fake_write "persistent" "0"
    fake_write "live" "0"

    run_command on
    assert_status 2
    assert_contains "SleepDisabled changed externally"
}

run_test() {
    local name
    local function_name
    local rc

    name="$1"
    function_name="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_ROOT=$(/usr/bin/mktemp -d "/tmp/no-sleep-tests.XXXXXX") || exit 1
    setup_case

    (
        set -e
        "$function_name"
    )
    rc=$?
    /bin/rm -rf "$TEST_ROOT"

    if [[ "$rc" -eq 0 ]]; then
        printf 'ok %d - %s\n' "$TESTS_RUN" "$name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf 'not ok %d - %s\n' "$TESTS_RUN" "$name"
    fi
}

run_test "status, help, and usage" test_status_help_and_usage
run_test "power parser contracts" test_power_parser_contracts
run_test "privileged command contract" test_privileged_command_contract
run_test "fresh on/off and idempotency" test_fresh_on_off_idempotent
run_test "pre-existing pmset is preserved" test_preserves_preexisting_pmset
run_test "force preserves a valid pre-existing baseline" test_force_preserves_valid_preexisting_baseline
run_test "display mode reconfiguration" test_display_mode_reconfiguration
run_test "toggle paths" test_toggle_paths
run_test "sudo cancellation is clean" test_sudo_cancel_has_no_side_effects
run_test "pmset false-success rolls back" test_pmset_false_success_rolls_back
run_test "pmset nonzero with verified change succeeds" test_pmset_nonzero_with_verified_change_succeeds
run_test "launchd submit failure rolls back" test_submit_failure_rolls_back
run_test "launchd submit nonzero with live job succeeds" test_submit_nonzero_with_live_job_succeeds
run_test "launchd removal failure retains recovery state" test_remove_failure_retains_recovery_state
run_test "reboot-style degraded recovery" test_reboot_style_degraded_recovery
run_test "corrupt state requires force" test_corrupt_state_requires_force
run_test "unowned global state requires force" test_unowned_global_requires_force
run_test "toggle refuses unowned global state" test_toggle_refuses_unowned_global_state
run_test "foreign job is never removed" test_foreign_job_is_never_removed
run_test "owned pmset restores despite foreign job shape" test_owned_pmset_restores_despite_foreign_job_shape
run_test "power drift after removal retains state" test_power_drift_after_job_removal_retains_state
run_test "power-source mismatch fails closed" test_mismatched_power_sources_fail_closed
run_test "unsafe state directory fails closed" test_unsafe_state_directory_fails_closed
run_test "concurrent operation fails fast" test_concurrent_operation_fails_fast
run_test "remove_state directory safety guard" test_remove_state_dir_safety_guard
run_test "toggle refuses corrupt state" test_toggle_refuses_corrupt_state
run_test "forced recovery restores sleep with unsafe state file" test_forced_recovery_restores_sleep_with_unsafe_state_file
run_test "external baseline invalidation drift" test_external_baseline_invalidation_drift

printf '1..%d\n' "$TESTS_RUN"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
    printf '%d test(s) failed\n' "$TESTS_FAILED" >&2
    exit 1
fi
printf 'all %d tests passed\n' "$TESTS_RUN"
