#!/usr/bin/env bash
# Waits for SwiftPM's `.build/.lock` to be free, or clears it when the process
# that took it is gone.
#
# Why this exists: a concurrent `swift build`/`swift test` does not fail fast
# on a busy `.build` — it blocks on `flock` with no output, so the caller sees
# a hang indistinguishable from a slow compile and typically kills it after
# ten minutes. Worse, a build killed mid-flight (or a crashed agent session)
# leaves the lock file behind with no live holder, and every later invocation
# blocks forever on nothing.
#
# The distinction this script makes is exactly the one a human makes: is the
# lock HELD (a real build is running — wait for it) or merely PRESENT (the
# owner died — clear it)? `lsof` answers the first; the PID SwiftPM writes
# into the file answers the second. Only when BOTH say "nobody" is the file
# removed.
#
# Usage:
#   script/await_build_lock.sh            # wait, then return 0 when free
#   RAFU_LOCK_ATTEMPTS=4 RAFU_LOCK_WAIT=180 script/await_build_lock.sh
#
# Exit codes: 0 free (or cleared), 1 still held after every attempt.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOCK_FILE=".build/.lock"
ATTEMPTS="${RAFU_LOCK_ATTEMPTS:-4}"
WAIT_SECONDS="${RAFU_LOCK_WAIT:-180}"

# The pids holding an flock on the file right now. Empty means nothing has it
# open, which is the authoritative "not held" signal — the file existing on
# disk says nothing by itself.
lock_holders() {
    [ -e "$LOCK_FILE" ] || return 0
    lsof -t -- "$LOCK_FILE" 2>/dev/null || true
}

# SwiftPM writes the owning pid into the lock file. Used only as the second
# half of the staleness test, never on its own: a recycled pid would read as
# "still alive" and a pid-less/empty file as "dead".
recorded_pid_is_alive() {
    local pid
    pid="$(tr -dc '0-9' <"$LOCK_FILE" 2>/dev/null | head -c 12)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

for attempt in $(seq 1 "$ATTEMPTS"); do
    if [ ! -e "$LOCK_FILE" ]; then
        exit 0
    fi

    holders="$(lock_holders)"
    if [ -z "$holders" ] && ! recorded_pid_is_alive; then
        echo "await_build_lock: $LOCK_FILE is stale (no holder, owner gone) — removing."
        rm -f "$LOCK_FILE"
        exit 0
    fi

    if [ -z "$holders" ]; then
        # No flock holder, but the recorded pid is alive: a build is starting
        # up or shutting down. Do NOT remove — just come back.
        echo "await_build_lock: owner still alive, lock not yet taken; attempt ${attempt}/${ATTEMPTS}."
    else
        echo "await_build_lock: held by pid(s) $(echo "$holders" | tr '\n' ' ')— attempt ${attempt}/${ATTEMPTS}."
    fi

    if [ "$attempt" -eq "$ATTEMPTS" ]; then
        break
    fi
    echo "await_build_lock: waiting ${WAIT_SECONDS}s…"
    sleep "$WAIT_SECONDS"
done

echo "await_build_lock: still held after ${ATTEMPTS} attempts." >&2
echo "A real build is running. Wait for it, or stop it before retrying." >&2
exit 1
