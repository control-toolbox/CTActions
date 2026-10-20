#!/usr/bin/env bash
# Checks the PAT behind RUNNERS_STATUS_TOKEN, before its failure is mistaken for
# something else.
#
# When this token expires, select-gpu-runner.yml silently falls back to occidata
# (a warning, no failure): the symptom is "CI got slow", not "token expired". This
# script calls the same endpoint with the token, reads the expiry GitHub reports in
# the `github-authentication-token-expiration` header of every response made with a
# PAT (no date to keep by hand), and opens an issue in CTActions when the token is
# rejected, lacks the permission, or expires within WARN_DAYS. The issue is closed
# again once everything is fine.
#
# Environment:
#   GH_TOKEN         github.token (issues:write on $REPO): the report must not depend
#                    on the secret it watches
#   TOKEN_UNDER_TEST the PAT (RUNNERS_STATUS_TOKEN); empty if the secret is not shared
#   ORG, REPO, WARN_DAYS (default 30)
#
# Exit: 0 if the token is fine or only expires soon; 1 if it is unusable.
set -euo pipefail

ORG="${ORG:-${GITHUB_REPOSITORY_OWNER:-control-toolbox}}"
REPO="${REPO:-${GITHUB_REPOSITORY:-control-toolbox/CTActions}}"
WARN_DAYS="${WARN_DAYS:-30}"
LABEL="token-expiry"
TITLE="RUNNERS_STATUS_TOKEN needs attention"
: "${GH_TOKEN:?GH_TOKEN required (issues:write on $REPO)}"

problem=""    # unusable: the exit status fails
warning=""    # still works
today="$(date -u +%Y-%m-%d)"

if [ -z "${TOKEN_UNDER_TEST:-}" ]; then
  problem="The secret \`RUNNERS_STATUS_TOKEN\` is not set, or not shared with CTActions. Every GPU choice falls back to occidata."
else
  resp="$(GH_TOKEN="$TOKEN_UNDER_TEST" gh api -i "orgs/$ORG/actions/runners?per_page=1" 2>&1 || true)"
  code="$(printf '%s\n' "$resp" | sed -n '1s/^HTTP[^ ]* \([0-9]*\).*/\1/p')"
  case "$code" in
    200)
      exp="$(printf '%s\n' "$resp" | tr -d '\r' | sed -n 's/^[Gg]ithub-authentication-token-expiration: *//p')"
      if [ -z "$exp" ]; then
        echo "OK: the token works; GitHub reports no expiry (a token without one)."
      else
        d="$(python3 -c 'import sys,datetime
e=datetime.date.fromisoformat(sys.argv[1][:10]); t=datetime.date.fromisoformat(sys.argv[2])
print((e-t).days)' "$exp" "$today")"
        echo "OK: the token works and expires on ${exp:0:10} (in $d days)."
        [ "$d" -le "$WARN_DAYS" ] && warning="The token expires on **${exp:0:10}** (in $d days). Create a new one and update the organization secret."
      fi ;;
    401) problem="GitHub rejects the token (401): it has **expired** or been revoked. Until it is replaced every GPU choice falls back to occidata." ;;
    403|404) problem="The token is valid but cannot list the organization's runners ($code): it needs the organization permission \"Self-hosted runners: read\" (and the organization must have approved it)." ;;
    *) problem="Unexpected answer from GitHub ($code) while testing the token: $(printf '%s\n' "$resp" | head -3 | tr '\n' ' ')" ;;
  esac
fi

gh label create "$LABEL" --repo "$REPO" --color d93f0b --description "A token or secret needs attention" 2>/dev/null || true
existing="$(gh issue list --repo "$REPO" --label "$LABEL" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"

if [ -z "$problem" ] && [ -z "$warning" ]; then
  if [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "$REPO" --body "The token is fine again on $today: closing." >/dev/null
    gh issue close "$existing" --repo "$REPO" --reason completed >/dev/null
  fi
  exit 0
fi

{
  echo "Checked on $today."
  echo
  [ -n "$problem" ] && printf '%s\n\n' "$problem"
  [ -n "$warning" ] && printf '%s\n\n' "$warning"
  echo "Renewal: see [select-gpu-runner.md](https://github.com/$REPO/blob/main/docs/workflows/select-gpu-runner.md#the-secret-runners_status_token)."
  echo
  echo "_Kept up to date by \`scripts/check-token-expiry.sh\`._"
} > "${RUNNER_TEMP:-/tmp}/token-body.md"

if [ -n "$existing" ]; then
  gh issue edit "$existing" --repo "$REPO" --body-file "${RUNNER_TEMP:-/tmp}/token-body.md" >/dev/null
else
  gh issue create --repo "$REPO" --title "$TITLE" --label "$LABEL" --assignee ocots --body-file "${RUNNER_TEMP:-/tmp}/token-body.md" >/dev/null
fi
[ -n "$problem" ] && { echo "::error::$problem"; exit 1; }
exit 0
