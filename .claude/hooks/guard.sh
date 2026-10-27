#!/usr/bin/env bash
# guard.sh - PreToolUse guard for Bash (and PowerShell) commands.   [Play 5]
#
# Blocks a short list of catastrophic commands BEFORE they run:
#   * recursive delete of /, ~, $HOME, ., .., *, a drive root, or a top-level system dir
#     (rm -rf /, rm -fr ~, sudo rm -r -f /, Remove-Item -Recurse C:\ ...)
#   * force-push to a protected branch (git push --force/-f origin main, git push origin +main,
#     or a bare force-push while the current branch is protected)
#   * disk wipers (mkfs*, dd of=/dev/..., redirect into /dev/sdX or /dev/nvmeX)
#
# Contract (Claude Code hooks): exit 2 = block the tool call and show stderr to Claude
# as the reason; exit 0 = no opinion (normal permission flow continues).
# Any other exit code is a NON-blocking error, so this script never uses one.
#
# Tunables (environment):
#   GUARD_PROTECTED_BRANCHES  space-separated, default "main master"
#   GUARD_FAIL_OPEN=1         if no JSON parser is available, allow instead of block
#   GUARD_DISABLE=1           turn the guard off entirely (not recommended)

. "$(dirname "$0")/lib/json.sh"
hook_read_input

[ "${GUARD_DISABLE:-0}" = "1" ] && exit 0

if ! json_parser_ok; then
  if [ "${GUARD_FAIL_OPEN:-0}" = "1" ]; then exit 0; fi
  echo "guard.sh cannot inspect this command: install jq or python3 (or set GUARD_FAIL_OPEN=1). Blocking to stay safe." >&2
  exit 2
fi

cmd=$(json_get .tool_input.command)
[ -z "$cmd" ] && exit 0

block() {
  printf 'Blocked by .claude/hooks/guard.sh: %s\nCommand: %s\n%s\n' "$1" "$cmd" "$2" >&2
  exit 2
}

# --- whole-string checks (disk wipers) -------------------------------------
lc=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')
if printf '%s' "$lc" | grep -Eq '(^|[^a-z0-9_.-])mkfs(\.[a-z0-9]+)?([[:space:]]|$)'; then
  block "mkfs formats a filesystem." "Do not format disks from an agent session."
fi
if printf '%s' "$lc" | grep -Eq '(^|[[:space:]])dd[[:space:]].*of=/dev/(sd|nvme|disk|hd|mmcblk|xvd|vd)'; then
  block "dd writing to a raw device." "Write to a regular file instead."
fi
if printf '%s' "$lc" | grep -Eq '>[[:space:]]*/dev/(sd[a-z]|nvme[0-9]|disk[0-9]|hd[a-z])'; then
  block "redirecting output onto a raw disk device." "Write to a regular file instead."
fi

# --- token-level checks ------------------------------------------------------
# Pad shell separators with spaces, then split into words without globbing.
norm=$(printf '%s' "$lc" | tr '\n\r\t`' ';;  ' | sed -e 's/&&/ ; /g' -e 's/||/ ; /g' -e 's/[;|&()]/ ; /g')
set -f
# shellcheck disable=SC2086
set -- $norm
# globbing stays off for the rest of the script ('*' is a target we inspect, not expand)

protected=" $(printf '%s' "${GUARD_PROTECTED_BRANCHES:-main master}" | tr '[:upper:]' '[:lower:]') "

strip_quotes() { printf '%s' "$1" | tr -d "\"'"; }

is_danger_target() {
  t=$(strip_quotes "$1")
  # normalise trailing slashes / backslashes, but keep a bare root
  while [ "${#t}" -gt 1 ] && { [ "${t%/}" != "$t" ] || [ "${t%\\}" != "$t" ]; }; do
    t=${t%/}; t=${t%\\}
  done
  case "$t" in
    /|/\*|\~|\~/\*|'$home'|'${home}'|'$home/*'|'${home}/*'|.|./\*|..|../\*|\*|\\) return 0 ;;
    '$env:userprofile'|'$env:home'|'$env:systemdrive'|'$env:windir') return 0 ;;
    [a-z]:|[a-z]:\\\*|[a-z]:/\*|/[a-z]|/mnt/[a-z]) return 0 ;;
    /bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/sbin|/srv|/sys|/usr|/var) return 0 ;;
    /applications|/library|/system|/users|/volumes|/private) return 0 ;;
  esac
  return 1
}

current_branch() {
  git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

# Walk the tokens segment by segment (segments are separated by ";").
mode=""          # "" | rm | push
recursive=0; targets=""; seen_git=0
force=0; plus_ref=""; dest_refs=""; positional=0

finish_segment() {
  if [ "$mode" = "rm" ] && [ "$recursive" = "1" ]; then
    for t in $targets; do
      if is_danger_target "$t"; then
        block "recursive delete of '$t'." "Delete a specific subdirectory by explicit path (for example rm -rf ./build), or ask the user to do this by hand."
      fi
    done
  fi
  if [ "$mode" = "push" ]; then
    if [ -n "$plus_ref" ]; then
      b=${plus_ref#+}; b=${b##*:}; b=${b#refs/heads/}
      case "$protected" in *" $b "*) block "force-push (+refspec) to protected branch '$b'." "Push to a feature branch, or use --force-with-lease on a non-protected branch." ;; esac
    fi
    if [ "$force" = "1" ]; then
      if [ -z "$dest_refs" ]; then
        b=$(current_branch)
        case "$protected" in *" $b "*) block "force-push while on protected branch '$b'." "Switch to a feature branch first; never force-push $b." ;; esac
      fi
      for r in $dest_refs; do
        b=${r##*:}; b=${b#refs/heads/}
        case "$protected" in *" $b "*) block "force-push to protected branch '$b'." "Use a feature branch, or --force-with-lease on a non-protected branch." ;; esac
      done
    fi
  fi
  mode=""; recursive=0; targets=""; seen_git=0; force=0; plus_ref=""; dest_refs=""; positional=0
}

for tok in "$@"; do
  if [ "$tok" = ";" ]; then finish_segment; continue; fi
  tok=$(strip_quotes "$tok")
  case "$mode" in
    "")
      case "$tok" in
        rm|*/rm|remove-item|ri|rmdir|rd)
          # 'git rm -r --cached .' only touches the index, not the disk
          if [ "$seen_git" = "1" ]; then mode="skip"; else mode="rm"; fi ;;
        git|*/git) seen_git=1 ;;
        push) [ "$seen_git" = "1" ] && mode="push" ;;
      esac
      ;;
    rm)
      case "$tok" in
        --recursive|-recurse|-recurs*) recursive=1 ;;
        --*) : ;;
        -*) case "$tok" in *r*) recursive=1 ;; esac ;;
        *) targets="$targets $tok" ;;
      esac
      ;;
    skip) : ;;
    push)
      case "$tok" in
        --force) force=1 ;;
        --force-with-lease*|--force-if-includes) : ;;
        --*) : ;;
        -*) case "$tok" in *f*) force=1 ;; esac ;;
        +*) plus_ref="$tok"; positional=$((positional + 1)) ;;
        *)
          positional=$((positional + 1))
          # first positional is the remote; the rest are refspecs
          if [ "$positional" -ge 2 ]; then
            case "$tok" in +*) plus_ref="$tok" ;; *) dest_refs="$dest_refs $tok" ;; esac
          fi
          ;;
      esac
      ;;
  esac
done
finish_segment

exit 0
