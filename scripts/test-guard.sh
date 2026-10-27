#!/usr/bin/env bash
# test-guard.sh - prove the guard hook works on THIS machine, without a model call.
#
# Feeds crafted PreToolUse payloads straight into .claude/hooks/guard.sh and
# checks the exit codes. Run it from the repo root:
#     bash scripts/test-guard.sh
# Zero tokens, zero network. Exit status = number of failed checks.

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
hooks="$root/.claude/hooks"
export CLAUDE_PROJECT_DIR="$root"
. "$hooks/lib/json.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

if json_parser_ok; then echo "JSON parser: $_JSON_TOOL"; else echo "JSON parser: NONE (install jq or python3)"; fi

# JSON-escape a string with the same parser the hook uses.
jstr() {
  if [ "$_JSON_TOOL" = "jq" ]; then printf '%s' "$1" | jq -Rs .
  else printf '%s' "$1" | "$_JSON_TOOL" -I -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.buffer.read().decode("utf-8")))'
  fi
}

pre_payload() {
  printf '{"session_id":"test","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s}}' "$(jstr "$1")"
}

expect_guard() { # expect_guard <0|2> <command>
  err=$(pre_payload "$2" | bash "$hooks/guard.sh" 2>&1 >/dev/null); rc=$?
  if [ "$rc" = "$1" ]; then ok "exit $rc: $2"; else bad "exit $rc (want $1): $2"; fi
  if [ "$1" = "2" ] && [ -z "$err" ]; then bad "no stderr reason for: $2"; fi
}

echo "Should block (exit 2):"
for c in 'rm -rf /' 'rm -fr ~' 'rm -r -f /' 'sudo rm -rf /' 'rm -rf /*' \
         'git push --force origin main' 'git push -f origin master' 'git push origin +main' \
         'Remove-Item -Recurse -Force C:\' 'mkfs.ext4 /dev/sdb1' 'dd if=/dev/zero of=/dev/sda bs=1M'; do
  expect_guard 2 "$c"
done
echo "Should allow (exit 0):"
for c in 'rm -rf ./build' 'rm -rf node_modules dist' 'git push --force-with-lease origin feat/x' \
         'git push origin main' 'git rm -r --cached .' 'ls -la' 'npm test'; do
  expect_guard 0 "$c"
done

echo
echo "passed=$pass failed=$fail"
exit "$fail"
