#!/usr/bin/env bash
# Sets a package up for release.yml: the environments, their secrets and the labels
# (docs/workflows/release.md#setting-it-up). Idempotent: run it again after a change of
# the token, or for a new package. Needs `gh` logged in as an administrator of the packages.
#
#   CT_RELEASE_CLIENT_ID=... CT_RELEASE_KEY_FILE=ct-release.private-key.pem \
#   CT_RELEASE_REGISTRATION_TOKEN=... \
#     bash scripts/release/setup.sh [--dry-run] [--autonomous] REPO...
#
# REPO is `owner/name`, or `name` for control-toolbox/name. The environment `release`
# (a required reviewer) is always set up; `release-autonomous` (no reviewer) only with
# `--autonomous`. The token of the registration comment is optional.
# CT_RELEASE_REVIEWER: the login of the reviewer (default: ocots).
set -euo pipefail

dry=false
autonomous=false
repos=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=true ;;
    --autonomous) autonomous=true ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    */*) repos+=("$a") ;;
    *) repos+=("control-toolbox/$a") ;;
  esac
done
[ ${#repos[@]} -gt 0 ] || { echo "no repository given" >&2; exit 2; }

: "${CT_RELEASE_CLIENT_ID:?the client id of the App ct-release}"
: "${CT_RELEASE_KEY_FILE:?the private key of the App ct-release (a .pem file)}"
[ -r "$CT_RELEASE_KEY_FILE" ] || { echo "cannot read $CT_RELEASE_KEY_FILE" >&2; exit 2; }
reviewer="${CT_RELEASE_REVIEWER:-ocots}"

# do <stdin file or -> <command...>: run it, or only print it with --dry-run
do_() {
  local in="$1"; shift
  if $dry; then echo "  [dry-run] $*"; return 0; fi
  if [ "$in" = - ]; then "$@" </dev/null; else "$@" <"$in"; fi
}

if $dry; then me=0; else me=$(gh api "users/$reviewer" --jq .id); fi
envs=(release)
$autonomous && envs+=(release-autonomous)
client=$(mktemp); trap 'rm -f "$client"' EXIT
printf %s "$CT_RELEASE_CLIENT_ID" >"$client"
token=""
if [ -n "${CT_RELEASE_REGISTRATION_TOKEN:-}" ]; then
  token=$(mktemp); trap 'rm -f "$client" "$token"' EXIT
  printf %s "$CT_RELEASE_REGISTRATION_TOKEN" >"$token"
fi

for repo in "${repos[@]}"; do
  echo "== $repo"
  if ! $dry; then
    [ "$(gh api "repos/$repo" --jq .permissions.admin)" = true ] \
      || { echo "  skipped: you are not an administrator of $repo" >&2; continue; }
  fi
  for env in "${envs[@]}"; do
    if [ "$env" = release ]; then
      body="{\"reviewers\": [{\"type\": \"User\", \"id\": $me}]}"
    else
      body='{}'
    fi
    if $dry; then echo "  [dry-run] gh api --method PUT repos/$repo/environments/$env  # $body"
    else gh api --method PUT "repos/$repo/environments/$env" --input - <<<"$body" >/dev/null; fi
    do_ "$client" gh secret set CT_RELEASE_CLIENT_ID -R "$repo" --env "$env"
    do_ "$CT_RELEASE_KEY_FILE" gh secret set CT_RELEASE_PRIVATE_KEY -R "$repo" --env "$env"
    [ -z "$token" ] || do_ "$token" gh secret set CT_RELEASE_REGISTRATION_TOKEN -R "$repo" --env "$env"
  done
  do_ - gh label create "release: supervised" -R "$repo" --force --color 0E8A16 \
    --description "Hand phases 4 to 8 of this release PR to Release, with approvals"
  $autonomous && do_ - gh label create "release: autonomous" -R "$repo" --force --color B60205 \
    --description "Hand phases 4 to 8 of this release PR to Release, without approvals"
  [ -n "$token" ] || echo "  no CT_RELEASE_REGISTRATION_TOKEN: the registration comment will be handed to a person"
  echo "  to check by hand: the App ct-release is installed on $repo (organization settings, Installed GitHub Apps)"
done
