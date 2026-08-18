#!/bin/sh
# End-to-end test against a stub herdr. Uses its own state dir, so it never
# touches the live daemon's lock, log or hold.
#
#   sh tests/test-inhibit.sh
#
# What it proves:
#   1. A working agent produces a real logind inhibitor.
#   2. A short idle blip does NOT drop the hold (the grace period works).
#   3. Sustained idle drops the hold, and both inhibitor layers exit with it.
#   4. Stopping the daemon releases the hold.

set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'sh "$REPO/inhibit.sh" stop >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT INT TERM

export HERDR_SLEEP_INHIBIT_STATE_DIR="$TMP/state"
export HERDR_SLEEP_INHIBIT_CONFIG="$TMP/config.env"
export HERDR_BIN="$TMP/herdr-stub"
mkdir -p "$HERDR_SLEEP_INHIBIT_STATE_DIR"

cat >"$TMP/config.env" <<'EOF'
POLL_SECONDS=1
IDLE_GRACE=3
MAX_HOLD_MINUTES=0
EOF

# The stub reports "working" or "idle" depending on a file the test writes.
cat >"$HERDR_BIN" <<EOF
#!/bin/sh
status=\$(cat "$TMP/status" 2>/dev/null || echo idle)
printf '{"result":{"agents":[{"pane_id":"p1","agent":"claude","agent_status":"%s"}]}}\n' "\$status"
EOF
chmod +x "$HERDR_BIN"

echo working >"$TMP/status"

fail() {
    echo "FAIL: $*" >&2
    sh "$REPO/inhibit.sh" status >&2 || true
    exit 1
}

hold_pids() {
    pgrep -f "hold-body $HERDR_SLEEP_INHIBIT_STATE_DIR/sleep-inhibit.lock" 2>/dev/null || true
}

# The logind inhibitor registered by *this* run: walk up from the hold marker to
# the systemd-inhibit that spawned it. Every hold, live or test, registers the
# same WHO and WHY, so matching on those would make the live daemon's inhibitor
# indistinguishable from ours and the assertions below meaningless.
hold_inhibitor_pid() {
    pid=$(hold_pids | head -n 1)
    [ -n "$pid" ] || return 1
    while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
        [ "$(ps -o comm= -p "$pid" 2>/dev/null || true)" = "systemd-inhibit" ] && {
            printf '%s\n' "$pid"
            return 0
        }
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    return 1
}

logind_lists_pid() {
    # WHO UID USER PID COMM WHAT WHY MODE; match the PID column on word boundaries.
    systemd-inhibit --list 2>/dev/null | grep -qE "(^|[[:space:]])$1([[:space:]]|$)"
}

/bin/sh "$REPO/inhibit.sh" daemon >"$TMP/daemon.log" 2>&1 &
daemon_pid=$!
sleep 3

[ -n "$(hold_pids)" ] || fail "no hold after 3s with a working agent"
inhibitor_pid=$(hold_inhibitor_pid) ||
    fail "hold taken but no systemd-inhibit parent found for it"
logind_lists_pid "$inhibitor_pid" ||
    fail "hold taken but its inhibitor (pid $inhibitor_pid) is not registered with logind"
echo "ok: hold acquired, logind inhibitor present"

# A one-poll blip must not drop the hold.
echo idle >"$TMP/status"
sleep 1
echo working >"$TMP/status"
sleep 2
[ -n "$(hold_pids)" ] || fail "hold dropped during a blip shorter than the grace period"
echo "ok: hold survived a short idle blip"

# Sustained idle must drop it, taking both inhibitor layers with it.
inhibitor_pid=$(hold_inhibitor_pid) || fail "no hold to release before the idle test"
echo idle >"$TMP/status"
sleep 6
[ -z "$(hold_pids)" ] || fail "hold not released after sustained idle"
kill -0 "$inhibitor_pid" 2>/dev/null &&
    fail "inhibitor process $inhibitor_pid outlived the hold"
logind_lists_pid "$inhibitor_pid" &&
    fail "logind inhibitor $inhibitor_pid outlived the hold"
echo "ok: hold released after sustained idle, both layers gone"

# Stopping the daemon must not leave a hold behind.
echo working >"$TMP/status"
sleep 3
[ -n "$(hold_pids)" ] || fail "hold not re-acquired after agent went back to working"
kill -TERM "$daemon_pid" 2>/dev/null || true
sleep 2
[ -z "$(hold_pids)" ] || fail "hold survived daemon shutdown"
echo "ok: hold re-acquired, then released on daemon stop"

echo "ALL TESTS PASSED"
