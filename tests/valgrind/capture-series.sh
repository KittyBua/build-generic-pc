#!/bin/bash
# Drive N /control/screenshot requests against a Neutrino that is already
# running under a valgrind tool, then shut it down cleanly.
#
# Usage, in two terminals (or one with the first backgrounded):
#
#   ALLOW_NON_ROOT=1 make run-valgrind        # or run-helgrind
#   N=50 tests/valgrind/capture-series.sh
#
# It exists because the phase-3 acceptance criterion is a SERIES --
# "ASan/Valgrind im PC-Build ohne Leck in 50 Serien-Shots" -- and a leak
# in the capture path only shows as a series: one capture leaking 3.6 MB
# and fifty leaking it look very different in a LEAK SUMMARY.
#
# Three traps are designed around, each of which has already cost a round
# on this build:
#
#  * The process is identified by the PID that HOLDS THE LISTENING
#    SOCKET, never by a process name. Under valgrind the program runs as
#    the tool binary (comm "memcheck-amd64-"), so "pgrep -x neutrino.real"
#    finds nothing and a name-based liveness check would report a healthy
#    run as dead.
#  * Nothing reads a log while the process is alive. Neutrino's stdout is
#    fully buffered when redirected, and a valgrind tool writes its
#    summaries only at exit.
#  * The shutdown is a SIGTERM that is WAITED for, and never escalated to
#    SIGKILL: a killed process writes no LEAK SUMMARY, so a run that had
#    to be killed has measured nothing and says so instead.
#
# Environment: PORT (31344, the developer web port), N (50), TAG (the
# name prefix, and so the /tmp/<TAG>-<i>.png files), READY_BUDGET,
# REQ_TIMEOUT, EXIT_BUDGET, OUT.
set -u
PORT="${PORT:-31344}"
N="${N:-50}"
TAG="${TAG:-vg}"
READY_BUDGET="${READY_BUDGET:-3000}"   # seconds to wait for the web server
REQ_TIMEOUT="${REQ_TIMEOUT:-600}"      # seconds per request
EXIT_BUDGET="${EXIT_BUDGET:-3600}"     # seconds to wait for a clean exit
OUT="${OUT:-/tmp/vg-drive.txt}"

: > "$OUT"
say() { echo "$(date '+%H:%M:%S') $*" >> "$OUT"; }

listener_pid() {
  ss -ltnpH "sport = :$PORT" 2>/dev/null |
    sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | head -1
}

say "waiting for port $PORT (budget ${READY_BUDGET}s)"
start=$SECONDS
while :; do
  if curl -s -o /dev/null --max-time 15 "http://127.0.0.1:$PORT/control/version"; then
    say "web server answered after $((SECONDS-start))s"
    break
  fi
  if [ $((SECONDS-start)) -gt "$READY_BUDGET" ]; then
    say "FAIL: port did not answer within ${READY_BUDGET}s"
    exit 3
  fi
  sleep 5
done

pid="$(listener_pid)"
if [ -z "$pid" ]; then
  say "FAIL: the port answers but no listening pid could be read"
  exit 4
fi
say "target pid $pid ($(cat /proc/$pid/comm 2>/dev/null))"

ok=0; bad=0; done_shots=0
shots_start=$SECONDS
for i in $(seq 1 "$N"); do
  t0=$SECONDS
  ans=$(curl -s --max-time "$REQ_TIMEOUT" \
        "http://127.0.0.1:$PORT/control/screenshot?name=$TAG-$i&osd=1&video=1")
  rc=$?
  ans="${ans//$'\n'/}"
  done_shots=$i
  if [ "$rc" -eq 0 ] && [ "$ans" = "ok" ]; then ok=$((ok+1)); else bad=$((bad+1)); fi
  say "shot $i: rc=$rc answer='${ans}' ($((SECONDS-t0))s)"
  if ! kill -0 "$pid" 2>/dev/null; then
    say "FAIL: pid $pid died during shot $i"
    break
  fi
done
say "captures: requested=$done_shots ok=$ok bad=$bad in $((SECONDS-shots_start))s"

if ! kill -0 "$pid" 2>/dev/null; then
  say "DONE-DEAD ok=$ok bad=$bad"
  exit 5
fi
say "SIGTERM to $pid for a clean shutdown"
kill -TERM "$pid"
t0=$SECONDS
while kill -0 "$pid" 2>/dev/null; do
  if [ $((SECONDS-t0)) -gt "$EXIT_BUDGET" ]; then
    say "FAIL: still alive ${EXIT_BUDGET}s after SIGTERM; NOT killing, the summary would be lost"
    exit 6
  fi
  sleep 5
done
say "exited after $((SECONDS-t0))s"
say "DONE ok=$ok bad=$bad shots=$done_shots"
