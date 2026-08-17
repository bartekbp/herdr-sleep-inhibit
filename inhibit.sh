#!/bin/sh
# Keep the machine awake while at least one herdr agent pane is "working".
#
# Design notes:
#
#   * A single long-lived daemon polls `herdr agent list`. Polling, rather than
#     reacting to plugin events only, means a dropped or never-delivered event
#     cannot leave the machine free to suspend in the middle of an unattended
#     run -- which is the exact failure this tool exists to prevent.
#
#   * A hold is a process chain: systemd-inhibit (logind suspend + IdleAction)
#     wrapping gnome-session-inhibit (gnome-settings-daemon's own idle-suspend
#     timer, which is driven by GNOME's idle monitor rather than by logind)
#     wrapping a marker process. Releasing kills the marker; both inhibitors are
#     its parents in the same chain and exit with it, so a hold cannot outlive
#     the daemon that took it.
#
#   * A hold is dropped only after IDLE_GRACE consecutive idle polls. Agents dip
#     out of "working" for a few seconds between turns, and releasing on every
#     dip re-exposes the machine to an idle-suspend timer that has long since
#     expired -- the inhibitor does not reset that timer, it only masks it.
#
#   * Only "working" counts. A "blocked" agent is waiting on the human, and the
#     human being away is precisely when suspending is the right behavior.

set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SELF="$SELF_DIR/$(basename -- "$0")"

# HERDR_SLEEP_INHIBIT_STATE_DIR exists so a test run can use its own lock, log
# and hold marker instead of fighting the live daemon for them.
STATE_DIR="${HERDR_SLEEP_INHIBIT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr}"
LOCK="$STATE_DIR/sleep-inhibit.lock"
PIDFILE="$STATE_DIR/sleep-inhibit.pid"
LOG="$STATE_DIR/sleep-inhibit.log"
CONFIG="${HERDR_SLEEP_INHIBIT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/sleep-inhibit/config.env}"

# Defaults; overridable from the environment, then from config.env.
POLL_SECONDS="${POLL_SECONDS:-10}"
# Consecutive idle polls before a hold is released. 6 * 10s smooths over the
# short idle blips between an agent finishing one turn and starting the next.
IDLE_GRACE="${IDLE_GRACE:-6}"
# Also inhibit idle actions (screen blank and lock) instead of suspend only.
# Off by default so the screen still locks on its normal timer while agents work.
INHIBIT_IDLE="${INHIBIT_IDLE:-0}"
# Also block suspend-on-lid-close. Off by default: closing the lid is an explicit
# request to suspend, and blocking it can cook a laptop in a bag.
INHIBIT_LID="${INHIBIT_LID:-0}"
# Minutes of continuous hold after which the daemon gives up regardless of agent
# state, until agents next report idle. Backstop against an agent stuck reporting
# "working" forever. 0 disables.
MAX_HOLD_MINUTES="${MAX_HOLD_MINUTES:-720}"

mkdir -p "$STATE_DIR"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

# The marker carries the lock path so that a test run with its own state dir
# never matches, and therefore never tears down, the live hold.
HOLD_MARKER="hold-body $LOCK"

log() {
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    # Under systemd, stdout is the journal and the log file would be a duplicate.
    if [ -n "${JOURNAL_STREAM:-}" ] || [ -n "${INVOCATION_ID:-}" ]; then
        printf '%s\n' "$line"
    else
        printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
    fi
}

trim_log() {
    # Keep the log bounded without needing logrotate.
    if [ -f "$LOG" ] && [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
        tail -n 500 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi
}

is_number() {
    case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
    esac
}

herdr_bin() {
    if [ -n "${HERDR_BIN:-}" ] && [ -x "$HERDR_BIN" ]; then
        printf '%s\n' "$HERDR_BIN"
        return 0
    fi
    if command -v herdr >/dev/null 2>&1; then
        command -v herdr
        return 0
    fi
    # herdr spawns plugin commands with no shell and with the server's PATH, so
    # the usual install locations are checked explicitly.
    for candidate in "$HOME/.local/bin/herdr" /usr/local/bin/herdr /opt/homebrew/bin/herdr; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# Prints the number of agents whose status is "working"; prints nothing and
# fails when herdr cannot be reached or its output cannot be parsed. A failed
# query counts as "not working", so a dead herdr server releases the hold
# instead of pinning the machine awake.
working_count() {
    bin=$(herdr_bin) || return 1
    "$bin" agent list 2>/dev/null | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(1)

agents = (payload.get("result") or {}).get("agents")
if not isinstance(agents, list):
    sys.exit(1)

print(sum(1 for a in agents if isinstance(a, dict) and a.get("agent_status") == "working"))
'
}

working_names() {
    bin=$(herdr_bin) || return 1
    "$bin" agent list 2>/dev/null | python3 -c '
import json
import sys

try:
    agents = (json.load(sys.stdin).get("result") or {}).get("agents") or []
except Exception:
    sys.exit(1)

for a in agents:
    if isinstance(a, dict) and a.get("agent_status") == "working":
        print("  %s  %s  %s" % (
            a.get("pane_id", "?"),
            a.get("agent", "?"),
            a.get("terminal_title_stripped") or "",
        ))
'
}

daemon_running() {
    # The lock is the authority, not a pid file or a pgrep pattern: the kernel
    # drops it the moment the holding process dies, however it died, and it is
    # scoped to this state dir so a test run and the live daemon never confuse
    # each other. flock -n succeeds only when nothing else holds the lock.
    ! flock -n "$LOCK" true 2>/dev/null
}

hold_active() {
    pgrep -f "$HOLD_MARKER" >/dev/null 2>&1
}

inhibit_what() {
    what="sleep"
    [ "$INHIBIT_IDLE" = "1" ] && what="$what:idle"
    [ "$INHIBIT_LID" = "1" ] && what="$what:handle-lid-switch"
    printf '%s' "$what"
}

acquire_hold() {
    reason="$1"

    if ! command -v systemd-inhibit >/dev/null 2>&1; then
        log "cannot hold: systemd-inhibit not found"
        return 1
    fi

    # gnome-session-inhibit is the layer that actually stops GNOME's
    # sleep-inactive-*-timeout; it is skipped on non-GNOME desktops, where the
    # logind layer still applies.
    if command -v gnome-session-inhibit >/dev/null 2>&1; then
        set -- gnome-session-inhibit
        if [ "$INHIBIT_IDLE" = "1" ]; then
            set -- "$@" --inhibit suspend:idle
        else
            set -- "$@" --inhibit suspend
        fi
        set -- "$@" --app-id herdr --reason "herdr agent working"
        set -- "$@" /bin/sh "$SELF" hold-body "$LOCK"
    else
        set -- /bin/sh "$SELF" hold-body "$LOCK"
    fi

    systemd-inhibit \
        --what="$(inhibit_what)" \
        --who="herdr" \
        --why="Herdr agent actively working" \
        --mode=block \
        "$@" >/dev/null 2>&1 &

    log "hold ON ($reason); what=$(inhibit_what) idle=$INHIBIT_IDLE"
}

release_hold() {
    reason="${1:-}"
    hold_active || return 0
    # Killing the marker is enough: gnome-session-inhibit and systemd-inhibit are
    # its parents in the same chain and exit as soon as their child does.
    pkill -f "$HOLD_MARKER" >/dev/null 2>&1 || true
    log "hold OFF${reason:+ ($reason)}"
}

usage() {
    cat >&2 <<'EOF'
usage: inhibit.sh <command>

  daemon       Poll agent state and hold the machine awake while any agent works.
               This is what the systemd unit runs.
  hook         Start the daemon if it is not already running (used by herdr
               plugin events; a no-op when the systemd unit is active).
  status       Show daemon state, active hold, effective config, working agents.
  stop         Stop the daemon and release any hold.
  logs         Print recent log lines.
EOF
    exit 2
}

case "${1:-}" in
daemon)
    exec 9>"$LOCK"
    # A second daemon exits immediately rather than fighting the first one.
    flock -n 9 || {
        log "daemon already running, exiting"
        exit 0
    }

    trim_log
    # A hold left behind by a SIGKILLed predecessor would otherwise never be
    # released, since nothing else knows about it.
    release_hold "stale hold from previous run"

    printf '%s\n' "$$" >"$PIDFILE"
    trap 'release_hold "daemon stopping"; rm -f "$PIDFILE"; exit 0' INT TERM

    log "daemon started (pid $$); poll=${POLL_SECONDS}s grace=${IDLE_GRACE} max_hold=${MAX_HOLD_MINUTES}m"

    holding=0
    idle_polls=0
    held_seconds=0
    # Set after MAX_HOLD_MINUTES fires, so the daemon does not immediately
    # re-acquire a hold for the same stuck agent. Cleared on the next idle poll.
    suppressed=0

    while :; do
        count=$(working_count 2>/dev/null || echo "")
        is_number "$count" || count=0

        if [ "$count" -gt 0 ]; then
            idle_polls=0
            if [ "$holding" -eq 0 ] && [ "$suppressed" -eq 0 ]; then
                if acquire_hold "$count working"; then
                    holding=1
                    held_seconds=0
                fi
            fi
        else
            suppressed=0
            idle_polls=$((idle_polls + 1))
            if [ "$holding" -eq 1 ] && [ "$idle_polls" -ge "$IDLE_GRACE" ]; then
                release_hold "no working agent for $((idle_polls * POLL_SECONDS))s"
                holding=0
            fi
        fi

        if [ "$holding" -eq 1 ] && is_number "$MAX_HOLD_MINUTES" &&
            [ "$MAX_HOLD_MINUTES" -gt 0 ] &&
            [ "$held_seconds" -ge $((MAX_HOLD_MINUTES * 60)) ]; then
            release_hold "max hold of ${MAX_HOLD_MINUTES}m reached"
            holding=0
            suppressed=1
        fi

        # A hold that outlived its process (killed by hand, OOM, a stray pkill)
        # must not leave the daemon believing it is still held.
        if [ "$holding" -eq 1 ] && ! hold_active; then
            log "hold vanished unexpectedly; will re-acquire"
            holding=0
        fi

        sleep "$POLL_SECONDS"
        [ "$holding" -eq 1 ] && held_seconds=$((held_seconds + POLL_SECONDS))
    done
    ;;

hook)
    daemon_running && exit 0
    setsid /bin/sh "$SELF" daemon >>"$LOG" 2>&1 &
    ;;

stop)
    if ! daemon_running; then
        release_hold "stop with no daemon"
        echo "sleep-inhibit: daemon not running"
        exit 0
    fi
    # The pid file is written by the daemon that holds this state dir's lock, so
    # this never reaches a daemon belonging to another state dir (a test run).
    pid=$(cat "$PIDFILE" 2>/dev/null || echo "")
    if is_number "$pid"; then
        kill -TERM "$pid" 2>/dev/null || true
    else
        echo "sleep-inhibit: daemon holds the lock but no pid file; not killing blindly" >&2
    fi
    # The daemon's TERM handler releases the hold; this covers a daemon that did
    # not get to run its trap.
    sleep 1
    release_hold "stopped manually"
    echo "sleep-inhibit: stopped"
    ;;

status)
    if daemon_running; then
        echo "daemon: running"
    else
        echo "daemon: not running"
    fi
    if hold_active; then
        echo "hold:   ACTIVE (machine will not idle-suspend)"
    else
        echo "hold:   none (normal sleep behavior)"
    fi
    echo "config: poll=${POLL_SECONDS}s grace=${IDLE_GRACE} polls what=$(inhibit_what) max_hold=${MAX_HOLD_MINUTES}m"
    count=$(working_count 2>/dev/null || echo "")
    if is_number "$count"; then
        echo "working agents: $count"
        [ "$count" -gt 0 ] && working_names
    else
        echo "working agents: unknown (herdr server unreachable)"
    fi
    # The two layers are visible in two different places: logind holds show up in
    # systemd-inhibit, GNOME session holds only in gnome-session-inhibit.
    echo "logind inhibitors:"
    systemd-inhibit --list 2>/dev/null | grep -E 'WHO|herdr' || true
    if command -v gnome-session-inhibit >/dev/null 2>&1; then
        echo "gnome session inhibitors:"
        gnome-session-inhibit --list 2>/dev/null | grep -A3 -i herdr || echo "  (none from herdr)"
    fi
    ;;

logs)
    if command -v journalctl >/dev/null 2>&1 &&
        journalctl --user -u herdr-inhibit -n 40 --no-pager >/dev/null 2>&1; then
        journalctl --user -u herdr-inhibit -n 40 --no-pager
    else
        tail -n 40 "$LOG" 2>/dev/null || echo "sleep-inhibit: no log yet"
    fi
    ;;

hold-body)
    # The innermost process of the inhibitor chain. It exists only to be killed:
    # its death tears down both inhibitors above it.
    while :; do
        sleep 3600
    done
    ;;

*)
    usage
    ;;
esac
