#!/usr/bin/env bash
# What label-dispatch.yml starts (docs/workflows/label-dispatch.md): one line per run,
# `<workflow file> <input>=<value>...`, on the standard output.
#
# Environment:
#   ACTION  the pull request event: labeled, synchronize, reopened
#   LABEL   the label that was just added (event `labeled`)
#   LABELS  JSON array of the labels the pull request carries
#   RESTART_LABELS  JSON array of labels that restart the CI (default none)
#   RESTART_PREFIX  prefix of labels that restart the CI (default none)
#
# The table is the one of docs/conventions/labels.md. On `labeled`, only the added label
# counts: the runs that other labels started are left alone. On any other event, every
# label of the pull request counts: a push or a reopening restarts them all.
# A package may name labels that are not a trigger but change what the CI runs (its scope):
# added while `run ci github-runner` is on the pull request, they dispatch the CI again.
# `documentation push preview` is a modifier: it starts nothing alone, and added after
# `run documentation` it starts the documentation again, with the preview.
set -euo pipefail

: "${ACTION:?}" "${LABELS:?}"
LABEL="${LABEL:-}"
RESTART_LABELS="${RESTART_LABELS:-[]}"
RESTART_PREFIX="${RESTART_PREFIX:-}"

has() { jq -e --arg l "$1" 'index($l) != null' <<< "$LABELS" > /dev/null; }

# the run a label starts; nothing for a label that does not start any
entry() {
  case "$1" in
    "run ci github-runner")      echo "CI.yml target=github" ;;
    "run ci occidata-runner")    echo "CI.yml target=occidata" ;;
    "run ci kkt-runner")         echo "CI.yml target=kkt" ;;
    "run breakage")              echo "Breakage.yml target=packages" ;;
    "run breakage applications") echo "Breakage.yml target=applications" ;;
    "run documentation")
      if has "documentation push preview"; then
        echo "Documentation.yml preview=true"
      else
        echo "Documentation.yml preview=false"
      fi ;;
  esac
}

restarts() {
  jq -e --arg l "$LABEL" 'index($l) != null' <<< "$RESTART_LABELS" > /dev/null ||
    { [ -n "$RESTART_PREFIX" ] && [[ "$LABEL" == "$RESTART_PREFIX"* ]]; }
}

if [ "$ACTION" = labeled ]; then
  if [ "$LABEL" = "documentation push preview" ]; then
    has "run documentation" && entry "run documentation"
  elif restarts; then
    has "run ci github-runner" && entry "run ci github-runner"
  else
    entry "$LABEL"
  fi
else
  while IFS= read -r label; do entry "$label"; done < <(jq -r '.[]' <<< "$LABELS")
fi
exit 0
