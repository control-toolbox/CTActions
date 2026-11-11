#!/usr/bin/env bash
# Tests of plan.sh: bash scripts/label-dispatch/test.sh
set -uo pipefail
plan="$(dirname "$0")/plan.sh"
failed=0

# check <name> <expected, one line per run> <ACTION> <LABEL> <LABELS>
check() {
  local name="$1" expected="$2" got
  got=$(ACTION="$3" LABEL="$4" LABELS="$5" "$plan") || { echo "FAIL $name: plan.sh failed"; failed=1; return; }
  if [ "$got" = "$expected" ]; then echo "ok   $name"; else
    echo "FAIL $name"; echo "  expected: $(echo "$expected" | tr '\n' ';')"; echo "  got:      $(echo "$got" | tr '\n' ';')"; failed=1
  fi
}

check "a label that starts nothing" "" \
  labeled bug '["bug","run ci kkt-runner"]'
check "a CI label starts its own runner only" "CI.yml target=kkt" \
  labeled "run ci kkt-runner" '["run ci github-runner","run ci kkt-runner"]'
check "documentation without the preview" "Documentation.yml preview=false" \
  labeled "run documentation" '["run documentation"]'
check "documentation, the preview label already there" "Documentation.yml preview=true" \
  labeled "run documentation" '["documentation push preview","run documentation"]'
check "the preview label after run documentation starts the documentation" "Documentation.yml preview=true" \
  labeled "documentation push preview" '["run documentation","documentation push preview"]'
check "the preview label alone starts nothing" "" \
  labeled "documentation push preview" '["documentation push preview"]'
check "breakage and breakage applications are two runs" "Breakage.yml target=applications" \
  labeled "run breakage applications" '["run breakage","run breakage applications"]'
check "a push restarts every labelled run" \
"CI.yml target=github
Documentation.yml preview=true
Breakage.yml target=packages" \
  synchronize "" '["run ci github-runner","bug","run documentation","documentation push preview","run breakage"]'
check "a pull request without label" "" \
  synchronize "" '[]'
check "a reopening restarts them too" "CI.yml target=occidata" \
  reopened "" '["run ci occidata-runner","probe"]'

exit $failed
