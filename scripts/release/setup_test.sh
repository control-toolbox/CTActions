#!/usr/bin/env bash
# Tests of setup.sh, with a fake `gh`: bash scripts/release/setup_test.sh
set -uo pipefail
setup="$(cd "$(dirname "$0")" && pwd)/setup.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
failed=0
log="$tmp/gh.log"
cat >"$tmp/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "api users/ocots") echo 42 ;;
  "api repos/control-toolbox/Admin") echo true ;;
  "api repos/control-toolbox/Reader") echo false ;;
  "api --method")
    # the body of the environment comes on stdin
    echo "gh $* <<< $(cat)" >>"$GH_LOG"; exit 0 ;;
  "secret set") echo "gh $* <<< $(cat)" >>"$GH_LOG"; exit 0 ;;
esac
echo "gh $*" >>"$GH_LOG"
FAKE
chmod +x "$tmp/gh"
printf 'KEY' >"$tmp/key.pem"
export PATH="$tmp:$PATH" GH_LOG="$log" CT_RELEASE_CLIENT_ID=Iv1.abc CT_RELEASE_KEY_FILE="$tmp/key.pem"

check() { # <name> <pattern> <file>
  if grep -qF -- "$2" "$3"; then echo "ok   $1"; else echo "FAIL $1: no '$2' in:"; sed 's/^/  /' "$3"; failed=1; fi
}
lacks() {
  if grep -qF -- "$2" "$3"; then echo "FAIL $1: found '$2'"; failed=1; else echo "ok   $1"; fi
}

: >"$log"
bash "$setup" Admin >"$tmp/out" 2>&1 || { echo "FAIL a run"; cat "$tmp/out"; failed=1; }
check "the environment release has the reviewer" '"id": 42' "$log"
check "the key is read from the file" "secret set CT_RELEASE_PRIVATE_KEY -R control-toolbox/Admin --env release <<< KEY" "$log"
check "the client id is a secret of the environment" "secret set CT_RELEASE_CLIENT_ID -R control-toolbox/Admin --env release <<< Iv1.abc" "$log"
check "the supervised label" "label create release: supervised -R control-toolbox/Admin --force" "$log"
lacks "no autonomous environment by default" "release-autonomous" "$log"
lacks "no token, no secret for it" "REGISTRATION_TOKEN" "$log"
check "a missing token is said" "no CT_RELEASE_REGISTRATION_TOKEN" "$tmp/out"

: >"$log"
CT_RELEASE_REGISTRATION_TOKEN=github_pat_x bash "$setup" --autonomous Admin >/dev/null 2>&1
check "the token is a secret of the environment" "secret set CT_RELEASE_REGISTRATION_TOKEN -R control-toolbox/Admin --env release <<< github_pat_x" "$log"
check "the autonomous environment" "environments/release-autonomous" "$log"
check "the autonomous label" "label create release: autonomous" "$log"

: >"$log"
bash "$setup" Reader >"$tmp/out" 2>&1
check "a repository without admin rights is skipped" "skipped" "$tmp/out"
lacks "and left alone" "secret set" "$log"

: >"$log"
bash "$setup" --dry-run owner/Name >"$tmp/out" 2>&1
check "dry run prints" "[dry-run] gh secret set CT_RELEASE_PRIVATE_KEY -R owner/Name" "$tmp/out"
if [ -s "$log" ]; then echo "FAIL dry run called gh"; failed=1; else echo "ok   dry run runs nothing"; fi

if CT_RELEASE_CLIENT_ID="" bash "$setup" Admin >/dev/null 2>&1; then echo "FAIL needs the client id"; failed=1; else echo "ok   the client id is required"; fi
exit $failed
