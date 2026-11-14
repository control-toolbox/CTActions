#!/usr/bin/env bash
# Which self-hosted GPU runner a job runs on (docs/workflows/select-gpu-runner.md): one
# line per output, `key=value`, on the standard output.
#
# Environment:
#   PREFERRED  label of the runner used when it is available (kkt)
#   FALLBACK   label of the runner used otherwise (occidata)
#   WHEN_BUSY  `wait` (default): only *offline* counts, a busy runner is waited for;
#              `skip`: a runner counts only if it is online and idle, and the job is
#              skipped when neither is (documentation.yml, CTActions#174)
#   RUNNERS    JSON array of the organization's runners, `[{labels, status, busy}]`;
#              empty when their state could not be read
#
# Outputs:
#   runner  the chosen label, empty when the job is skipped
#   skip    `true` when the job must be skipped, `false` otherwise
#   reason  one sentence for the log
#
# When the state is unknown, the fallback is chosen and nothing is skipped, whatever
# WHEN_BUSY: the job runs, possibly slower (principle 7, in doubt the safe side).
set -euo pipefail

: "${PREFERRED:?}" "${FALLBACK:?}"
WHEN_BUSY="${WHEN_BUSY:-wait}"
RUNNERS="${RUNNERS:-}"

case "$WHEN_BUSY" in
  wait|skip) ;;
  *) echo "WHEN_BUSY must be 'wait' or 'skip', got '$WHEN_BUSY'" >&2; exit 2 ;;
esac

out() { printf 'runner=%s\nskip=%s\nreason=%s\n' "$1" "$2" "$3"; }

if [ -z "$RUNNERS" ]; then
  out "$FALLBACK" false "state of the runners unknown: using '$FALLBACK'"
  exit 0
fi

# a runner with the label <label> that is online (and, for `idle`, not busy)
has() {
  local label="$1" idle="$2"
  jq -e --arg l "$label" --argjson idle "$idle" \
    'any(.[]; any(.labels[]; . == $l) and .status == "online" and (($idle | not) or (.busy | not)))' \
    <<< "$RUNNERS" > /dev/null
}

if [ "$WHEN_BUSY" = wait ]; then
  if has "$PREFERRED" false; then
    out "$PREFERRED" false "'$PREFERRED' is online"
  else
    out "$FALLBACK" false "'$PREFERRED' is offline: using '$FALLBACK'"
  fi
  exit 0
fi

for label in "$PREFERRED" "$FALLBACK"; do
  if has "$label" true; then
    out "$label" false "'$label' is online and idle"
    exit 0
  fi
done
out "" true "neither '$PREFERRED' nor '$FALLBACK' is online and idle: skipping"
