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

# --- v0.2: every bypass found by growth/run_bypass.py has a test here (kit and starter stay in step) ---
mainrepo=$(mktemp -d "${TMPDIR:-/tmp}/guard-main.XXXXXX")
git init -q "$mainrepo" >/dev/null 2>&1 && git -C "$mainrepo" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
expect_guard_main() { # expect_guard_main <0|2> <command>: same, but the current branch is main
  err=$(pre_payload "$2" | CLAUDE_PROJECT_DIR="$mainrepo" bash "$hooks/guard.sh" 2>&1 >/dev/null); rc=$?
  if [ "$rc" = "$1" ]; then ok "exit $rc (on main): $2"; else bad "exit $rc (want $1, on main): $2"; fi
}
each() { # each <0|2> : one command per line on stdin
  while IFS= read -r c; do [ -n "$c" ] && expect_guard "$1" "$c"; done
}

echo "Bypasses closed in v0.2 (exit 2):"
each 2 <<'EOF'
\rm -rf /
r\m -rf /
rm${IFS}-rf${IFS}/
rm$IFS-rf$IFS/
{rm,-rf,/}
rm --recursive --force /
rm -rf /.
rm -rf /tmp/../etc
rm -rf ../..
rm -rf /usr/*
rm -rf .*
rm -rf "$PWD"
find / -delete
find ~ -exec rm -rf {} +
find . -delete
git push --force-with-lease origin main
git push origin --delete main
git push origin :main
git push --force --all
git push --force origin refs/heads/*:refs/heads/*
git push -fu origin main
dd if=/dev/zero of="/dev/sda" bs=1M
wipefs -a /dev/sda
shred -n1 /dev/sdb
echo x | tee /dev/nvme0n1
cmd /c del /s /q C:\*
cmd /c rd /s /q C:\
sed -i 's/exit 2/exit 0/' .claude/hooks/guard.sh
echo exit 0 > .claude/hooks/guard.sh
rm .claude/settings.json
sed -i.bak 's/exit 2/exit 0/' .claude/hooks/guard.sh
sed -E -i 's/a/b/' .claude/settings.json
sed --in-place 's/a/b/' .claude/hooks/guard.sh
perl -pi -e 's/2/0/' .claude/hooks/guard.sh
cp /tmp/x .claude/hooks/guard.sh
EOF
expect_guard_main 2 'git push --force origin HEAD'
expect_guard_main 2 'git push --force'

echo "Must stay allowed (exit 0):"
each 0 <<'EOF'
cmd /c rd /s /q build
find . -name '*.pyc' -delete
find ./build -delete
find . -maxdepth 1 -type f -delete
rm -rf ../build
rm -rf ./build/../dist
rm -rf ${TMPDIR}/build
git push origin --delete feat/old-branch
git push origin feat/x
dd if=/dev/sda of=disk.img bs=1M count=1
cat .claude/settings.json
ls .claude/hooks
sed -i 's/a/b/' src/app.py
cp .claude/hooks/guard.sh /tmp/backup.sh
sed --expression=s/a/b/ .claude/settings.json
sed -n 1,5p .claude/hooks/guard.sh
EOF

echo "Known gaps: allowed because a pattern match cannot see them (documented, not fixed):"
each 0 <<'EOF'
$(echo rm) -rf /
x=/; rm -rf "$x"
xargs rm -rf < dirs.txt
echo cm0gLXJmIC8= | base64 -d | sh
python3 -c "import shutil; shutil.rmtree('/')"
git yeet origin main
Get-ChildItem C:\ -Recurse | Remove-Item -Force
EOF

echo "Accepted over-block (the guard cannot tell quoted text from a command):"
expect_guard 2 'echo "docs: never run rm -rf / on a server"'
rm -rf "$mainrepo"

echo
echo "passed=$pass failed=$fail"
exit "$fail"
