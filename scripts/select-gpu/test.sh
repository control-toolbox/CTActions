#!/usr/bin/env bash
# Tests of pick.sh: bash scripts/select-gpu/test.sh
set -uo pipefail
pick="$(dirname "$0")/pick.sh"
failed=0

# check <name> <expected runner> <expected skip> <WHEN_BUSY> <RUNNERS>
check() {
  local name="$1" runner="$2" skip="$3" got
  got=$(PREFERRED=kkt FALLBACK=occidata WHEN_BUSY="$4" RUNNERS="$5" "$pick") ||
    { echo "FAIL $name: pick.sh failed"; failed=1; return; }
  local expected
  expected=$(printf 'runner=%s\nskip=%s' "$runner" "$skip")
  if [ "$(grep -v '^reason=' <<< "$got")" = "$expected" ]; then echo "ok   $name"; else
    echo "FAIL $name"; echo "  expected: $(tr '\n' ';' <<< "$expected")"; echo "  got:      $(tr '\n' ';' <<< "$got")"; failed=1
  fi
}

runner() { printf '{"labels":["self-hosted","Linux","gpu","%s"],"status":"%s","busy":%s}' "$1" "$2" "$3"; }
KKT_IDLE=$(runner kkt online false)
KKT_BUSY=$(runner kkt online true)
KKT_OFF=$(runner kkt offline false)
OCC_IDLE=$(runner occidata online false)
OCC_BUSY=$(runner occidata online true)
OCC_OFF=$(runner occidata offline false)
PIN=$(runner pinwheel online false)

# --- wait (ci-gpu.yml): only offline counts, today's behaviour ----------------------------
check "wait: kkt online and idle"         kkt      false wait "[$KKT_IDLE,$OCC_IDLE]"
check "wait: kkt busy is waited for"      kkt      false wait "[$KKT_BUSY,$OCC_IDLE]"
check "wait: kkt offline, occidata"       occidata false wait "[$KKT_OFF,$OCC_IDLE]"
check "wait: both busy, still occidata"   occidata false wait "[$KKT_OFF,$OCC_BUSY]"
check "wait: kkt unknown to the org"      occidata false wait "[$OCC_IDLE,$PIN]"
check "wait is the default"               kkt      false ""   "[$KKT_BUSY,$OCC_IDLE]"

# --- skip (documentation.yml): online and idle, else skip ---------------------------------
check "skip: kkt online and idle"         kkt      false skip "[$KKT_IDLE,$OCC_IDLE]"
check "skip: kkt busy, occidata idle"     occidata false skip "[$KKT_BUSY,$OCC_IDLE]"
check "skip: kkt offline, occidata idle"  occidata false skip "[$KKT_OFF,$OCC_IDLE]"
check "skip: kkt offline, occidata busy"  ""       true  skip "[$KKT_OFF,$OCC_BUSY]"
check "skip: both busy"                   ""       true  skip "[$KKT_BUSY,$OCC_BUSY]"
check "skip: both offline"                ""       true  skip "[$KKT_OFF,$OCC_OFF]"
check "skip: another GPU runner is ignored" ""     true  skip "[$KKT_OFF,$OCC_BUSY,$PIN]"
check "skip: one idle runner among two kkt" kkt    false skip "[$KKT_BUSY,$KKT_IDLE,$OCC_BUSY]"
check "skip: no runner at all"            ""       true  skip "[]"

# --- unknown state: the fallback, never skipped (principle 7) -------------------------------
check "unknown state, wait"               occidata false wait ""
check "unknown state, skip"               occidata false skip ""

# --- errors -------------------------------------------------------------------------------
if PREFERRED=kkt FALLBACK=occidata WHEN_BUSY=sometimes RUNNERS="[]" "$pick" 2>/dev/null; then
  echo "FAIL an unknown WHEN_BUSY is rejected"; failed=1
else echo "ok   an unknown WHEN_BUSY is rejected"; fi

reason=$(PREFERRED=kkt FALLBACK=occidata WHEN_BUSY=skip RUNNERS="[$KKT_OFF,$OCC_BUSY]" "$pick" | sed -n 's/^reason=//p')
if [ -n "$reason" ]; then echo "ok   a reason is given"; else echo "FAIL a reason is given"; failed=1; fi

exit "$failed"
