# shellcheck shell=sh
# Shared JSON helpers for the Agent Runbook Kit hooks.
# Sourced (not executed) by every hook script.
#
# Parser order: jq if it is on PATH, else a python3/python that actually runs.
# Nothing else is required. If neither exists, json_parser_ok returns 1 and
# each hook decides whether to fail open or closed.
#
# Usage inside a hook:
#   . "$(dirname "$0")/lib/json.sh"
#   hook_read_input                  # reads stdin once into $HOOK_INPUT
#   cmd=$(json_get .tool_input.command)
#   json_context SessionStart "text" # prints a hookSpecificOutput object

HOOK_INPUT=""
_JSON_TOOL=""

_json_detect() {
  [ -n "$_JSON_TOOL" ] && return 0
  if command -v jq >/dev/null 2>&1; then
    _JSON_TOOL="jq"
    return 0
  fi
  for _py in python3 python; do
    # The Windows Store "python3" stub exists on PATH but does not run,
    # so test-execute instead of trusting command -v.
    if command -v "$_py" >/dev/null 2>&1 && "$_py" -I -c 'import json,sys; sys.exit(0)' >/dev/null 2>&1; then
      _JSON_TOOL="$_py"
      return 0
    fi
  done
  _JSON_TOOL="none"
  return 1
}

json_parser_ok() {
  _json_detect
  [ "$_JSON_TOOL" != "none" ]
}

hook_read_input() {
  HOOK_INPUT=$(cat)
}

# json_get .a.b.c  -> prints the value at that path from $HOOK_INPUT.
# Missing/null prints nothing. Booleans print true/false. Objects print JSON.
json_get() {
  _json_detect || return 1
  if [ "$_JSON_TOOL" = "jq" ]; then
    printf '%s' "$HOOK_INPUT" | jq -r "$1 | if . == null then empty elif type == \"string\" then . else tojson end" 2>/dev/null
  else
    printf '%s' "$HOOK_INPUT" | "$_JSON_TOOL" -I -c '
import json, sys
try:
    data = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace") or "null")
except ValueError:
    sys.exit(0)
for key in [k for k in sys.argv[1].split(".") if k]:
    data = data.get(key) if isinstance(data, dict) else None
if data is None:
    sys.exit(0)
if isinstance(data, bool):
    out = "true" if data else "false"
elif isinstance(data, (dict, list)):
    out = json.dumps(data)
else:
    out = str(data)
sys.stdout.buffer.write(out.encode("utf-8"))
' "$1" 2>/dev/null
  fi
}

# json_context <EventName> <text>  -> {"hookSpecificOutput":{"hookEventName":..,"additionalContext":..}}
json_context() {
  _json_detect || return 1
  if [ "$_JSON_TOOL" = "jq" ]; then
    jq -cn --arg e "$1" --arg c "$2" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
  else
    printf '%s' "$2" | "$_JSON_TOOL" -I -c '
import json, sys
text = sys.stdin.buffer.read().decode("utf-8", "replace")
out = {"hookSpecificOutput": {"hookEventName": sys.argv[1], "additionalContext": text}}
sys.stdout.buffer.write(json.dumps(out).encode("utf-8"))
' "$1"
  fi
}
