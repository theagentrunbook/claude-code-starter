#!/usr/bin/env bash
# guard.sh - PreToolUse guard for Bash (and PowerShell) commands.   [Play 5]   v0.2
#
# Blocks a short list of catastrophic commands BEFORE they run:
#   * recursive delete of /, ~, $HOME, ., .., .*, *, a drive root, or a top-level system dir
#     (rm -rf /, rm -fr ~, sudo rm -r -f /, \rm -rf /, rm -rf /usr/*, Remove-Item -Recurse C:\ ...),
#     including the find / -delete and find / -exec rm forms
#   * force-push (including --force-with-lease, --all and wildcard refspecs) to a protected branch,
#     deleting a protected branch, or a bare force-push while the current branch is protected
#   * disk wipers (mkfs*, dd of=/dev/..., redirect into /dev/sdX, tee/shred/wipefs/blkdiscard on a disk)
#   * shell edits to this hook or to .claude/settings*.json
#
# This is defense-in-depth, NOT a sandbox. It reads the command TEXT. Anything that hides the
# destructive part from the text (a variable, $(...), base64, a script file, python -c, xargs,
# an alias) gets through. Pair it with permissions.deny rules and a throwaway environment.
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

# --- whole-string checks (disk wipers, hook tampering) ----------------------
# lcw = lower-cased, with quotes and backslashes removed, so of="/dev/sda" and mk\fs still match.
lc=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')
lcw=$(printf '%s' "$lc" | tr -d "\"'\\\\")
DEV='/dev/(sd|nvme|r?disk|hd|mmcblk|xvd|vd)'
if printf '%s' "$lcw" | grep -Eq '(^|[^a-z0-9_.-])mkfs(\.[a-z0-9]+)?([[:space:]]|$)'; then
  block "mkfs formats a filesystem." "Do not format disks from an agent session."
fi
if printf '%s' "$lcw" | grep -Eq "(^|[[:space:]])dd[[:space:]].*of=$DEV"; then
  block "dd writing to a raw device." "Write to a regular file instead."
fi
if printf '%s' "$lcw" | grep -Eq ">[[:space:]]*$DEV"; then
  block "redirecting output onto a raw disk device." "Write to a regular file instead."
fi
if printf '%s' "$lcw" | grep -Eq "(^|[^a-z0-9_.-])(tee|shred|wipefs|blkdiscard|mke2fs|mkswap)[[:space:]][^;|&]*$DEV"; then
  block "wiping or writing a raw disk device." "Do not write to disk devices from an agent session."
fi
# Editing the guard (or the settings that wire it) from the shell is how it gets switched off.
# (The Edit and Write tools are not Bash; cover them with permissions.deny rules.)
HOOKPATH='\.claude/(hooks/|settings)'
INPLACE='(-[a-z]*i[^[:space:]]*|--in-place[^[:space:]]*)'
if printf '%s' "$lcw" | grep -Eq ">>?[[:space:]]*[^[:space:];|&]*$HOOKPATH" \
   || printf '%s' "$lcw" | grep -Eq "(^|[^a-z0-9_.-])(tee|chmod|truncate|mv|rm|ln)[[:space:]][^;|&]*$HOOKPATH" \
   || printf '%s' "$lcw" | grep -Eq "(^|[^a-z0-9_.-])(sed|perl)[[:space:]]+([^;|&]*[[:space:]])?$INPLACE[[:space:]][^;|&]*$HOOKPATH" \
   || printf '%s' "$lcw" | grep -Eq "(^|[^a-z0-9_.-])(cp|install)[[:space:]][^;|&]*[[:space:]][^[:space:];|&]*$HOOKPATH[^[:space:];|&]*[[:space:]]*($|[;|&])"; then
  block "this command edits the guard hook or .claude/settings*.json." "Ask the user to change hook configuration by hand."
fi

# --- token-level checks ------------------------------------------------------
# Pad shell separators with spaces, then split into words without globbing.
# \${IFS} / \$IFS are word separators in the shell, so treat them as spaces (rm${IFS}-rf${IFS}/).
norm=$(printf '%s' "$lc" | tr '\n\r\t`' ';;  ' | sed -e 's/\${ifs[^}]*}/ /g' -e 's/\$ifs/ /g' -e 's/\$[0-9]//g' \
        -e 's/&&/ ; /g' -e 's/||/ ; /g' -e 's/[;|&()]/ ; /g')
# Brace expansion ({rm,-rf,/}) -> plain words. ${VAR} braces are left alone.
if printf '%s' "$norm" | grep -Eq '(^|[^$])\{[^{}$]*,[^{}]*\}'; then
  norm=$(printf '%s' "$norm" | sed -E -e 's/(^|[^$])\{/\1 /g' -e 's/(^|[^$])\}/\1 /g' | tr ',' ' ')
fi
set -f
# shellcheck disable=SC2086
set -- $norm
# globbing stays off for the rest of the script ('*' is a target we inspect, not expand)

protected=" $(printf '%s' "${GUARD_PROTECTED_BRANCHES:-main master}" | tr '[:upper:]' '[:lower:]') "

strip_quotes() { _sq=${1//[\"\']/}; printf '%s' "$_sq"; }

# Lexical path cleanup (no filesystem access): collapses //, /./ and a/../ so /tmp/../etc is /etc.
norm_path() {
  _p=$1; _abs=0; case "$_p" in /*) _abs=1 ;; esac
  _out=""; _old=$IFS; IFS=/
  for _c in $_p; do
    case "$_c" in
      ""|.) : ;;
      ..) case "$_out" in
            "") [ "$_abs" = 1 ] || _out=".." ;;
            ..|*/..) _out="$_out/.." ;;
            */*) _out=${_out%/*} ;;
            *) _out="" ;;
          esac ;;
      *) _out="${_out:+$_out/}$_c" ;;
    esac
  done
  IFS=$_old
  if [ "$_abs" = 1 ]; then printf '/%s' "$_out"; else printf '%s' "${_out:-.}"; fi
}

danger_one() {
  case "$1" in
    /|/\*|\~|\~/\*|'$home'|'${home}'|'$home/*'|'${home}/*'|.|./\*|..|../\*|\*|\\) return 0 ;;
    .\*|./.\*|'$pwd'|'${pwd}') return 0 ;;
  esac
  # ../.. , ../../.. : climbing out of the project by any number of levels
  u=$1; while [ "${u#../}" != "$u" ]; do u=${u#../}; done
  case "$u" in ..|../\*) return 0 ;; esac
  case "$1" in
    '$env:userprofile'|'$env:home'|'$env:systemdrive'|'$env:windir') return 0 ;;
    [a-z]:|[a-z]:\\\*|[a-z]:/\*|/[a-z]|/mnt/[a-z]) return 0 ;;
    /bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/sbin|/srv|/sys|/usr|/var) return 0 ;;
    /applications|/library|/system|/users|/volumes|/private) return 0 ;;
  esac
  return 1
}

is_danger_target() {
  t=$(strip_quotes "$1")
  # normalise trailing slashes / backslashes, but keep a bare root
  while [ "${#t}" -gt 1 ] && { [ "${t%/}" != "$t" ] || [ "${t%\\}" != "$t" ]; }; do
    t=${t%/}; t=${t%\\}
  done
  case "$t" in *\\*) : ;; *) t=$(norm_path "$t") ;; esac
  danger_one "$t" && return 0
  # /usr/* , /etc/* , ...: deleting everything inside a protected directory
  case "$t" in
    */\*) b=${t%/\*}; [ -z "$b" ] && b=/; danger_one "$b" && return 0 ;;
  esac
  return 1
}

# '.'-style targets only count for find when no filter narrows the match
is_cwdish() {
  case "$1" in .|./\*|..|../\*|.\*|./.\*|\*) return 0 ;; esac
  return 1
}

current_branch() {
  git -C "${CLAUDE_PROJECT_DIR:-.}" symbolic-ref --short -q HEAD 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

# HEAD and @ mean "the current branch" in a refspec.
resolve_ref() {
  case "$1" in head|@) current_branch ;; *) printf '%s' "$1" ;; esac
}

check_protected() { # check_protected <ref> <what>
  b=${1##*:}; b=${b#+}; b=${b#refs/heads/}; b=$(resolve_ref "$b")
  case "$b" in
    \*) block "$2 with a wildcard refspec (matches protected branches)." "Name the branch you mean." ;;
  esac
  case "$protected" in *" $b "*) block "$2 protected branch '$b'." "Use a feature branch; never rewrite or delete $b." ;; esac
}

# Walk the tokens segment by segment (segments are separated by ";").
mode=""          # "" | rm | push | find | skip
recursive=0; targets=""; seen_git=0; winlike=0
force=0; all=0; del=0; plus_ref=""; dest_refs=""; colon_refs=""; positional=0
fpaths=""; frest=""; fpast=0

finish_segment() {
  if [ "$mode" = "rm" ] && [ "$recursive" = "1" ]; then
    for t in $targets; do
      if is_danger_target "$t"; then
        block "recursive delete of '$t'." "Delete a specific subdirectory by explicit path (for example rm -rf ./build), or ask the user to do this by hand."
      fi
    done
  fi
  if [ "$mode" = "find" ]; then
    f=" $frest "; fdel=0
    case "$f" in *" -delete "*) fdel=1 ;; esac
    case "$f" in *" -exec "*|*" -execdir "*|*" -ok "*|*" -okdir "*)
      case "$f" in *" rm "*|*" rmdir "*|*" shred "*|*" unlink "*) fdel=1 ;; esac ;;
    esac
    filtered=0
    for k in name iname path ipath regex iregex type mtime mmin atime ctime newer size user group perm empty lname; do
      case "$f" in *" -$k "*) filtered=1 ;; esac
    done
    if [ "$fdel" = "1" ]; then
      [ -z "$fpaths" ] && fpaths="."
      for t in $fpaths; do
        if is_danger_target "$t"; then
          if is_cwdish "$t" && [ "$filtered" = "1" ]; then continue; fi
          block "find over '$t' with -delete or -exec rm." "Name an explicit subdirectory (for example find ./build -delete), or ask the user to do this by hand."
        fi
      done
    fi
  fi
  if [ "$mode" = "push" ]; then
    if [ -n "$plus_ref" ]; then check_protected "$plus_ref" "force-push (+refspec) to"; fi
    if [ "$force" = "1" ]; then
      if [ "$all" = "1" ]; then
        block "force-push with --all includes protected branches." "Push the one feature branch you mean."
      fi
      if [ -z "$dest_refs" ]; then
        b=$(current_branch)
        case "$protected" in *" $b "*) block "force-push while on protected branch '$b'." "Switch to a feature branch first; never force-push $b." ;; esac
      fi
      for r in $dest_refs; do check_protected "$r" "force-push to"; done
    fi
    if [ "$del" = "1" ]; then
      for r in $dest_refs; do check_protected "$r" "deleting"; done
    fi
    for r in $colon_refs; do check_protected "$r" "deleting"; done
  fi
  mode=""; recursive=0; targets=""; seen_git=0; winlike=0
  force=0; all=0; del=0; plus_ref=""; dest_refs=""; colon_refs=""; positional=0
  fpaths=""; frest=""; fpast=0
}

for tok in "$@"; do
  if [ "$tok" = ";" ]; then finish_segment; continue; fi
  tok=${tok//[\"\']/}
  # \rm and r\m both run plain rm; use the backslash-free spelling to recognise command names
  name=${tok//\\/}
  case "$mode" in
    "")
      case "$name" in
        rm|*/rm|remove-item|ri|rmdir|rd|del|erase)
          # 'git rm -r --cached .' only touches the index, not the disk
          if [ "$seen_git" = "1" ]; then mode="skip"; else
            mode="rm"
            case "$name" in rd|rmdir|del|erase) winlike=1 ;; esac
            case "$name" in del|erase) recursive=1 ;; esac
          fi ;;
        find|*/find) [ "$seen_git" = "1" ] || mode="find" ;;
        git|*/git) seen_git=1 ;;
        push) [ "$seen_git" = "1" ] && mode="push" ;;
      esac
      ;;
    rm)
      case "$tok" in
        --recursive|-recurse|-recurs*) recursive=1 ;;
        --*) : ;;
        /[a-z?]) # cmd.exe switch (/s /q) for rd, rmdir, del; a real path elsewhere
          if [ "$winlike" = "1" ]; then [ "$tok" = "/s" ] && recursive=1; else targets="$targets $tok"; fi ;;
        -*) case "$tok" in *r*) recursive=1 ;; esac ;;
        *) targets="$targets $tok" ;;
      esac
      ;;
    find)
      case "$tok" in
        -*|\!) fpast=1; frest="$frest $tok" ;;
        *) if [ "$fpast" = "0" ]; then fpaths="$fpaths $tok"; else frest="$frest $tok"; fi ;;
      esac
      ;;
    skip) : ;;
    push)
      case "$tok" in
        --force|--force-with-lease*|--force-if-includes) force=1 ;;
        --all) all=1 ;;
        --delete|-d) del=1 ;;
        --*) : ;;
        -*) case "$tok" in *f*) force=1 ;; esac ;;
        +*) plus_ref="$tok"; positional=$((positional + 1)) ;;
        *)
          positional=$((positional + 1))
          # first positional is the remote; the rest are refspecs
          if [ "$positional" -ge 2 ]; then
            case "$tok" in
              +*) plus_ref="$tok" ;;
              :*) colon_refs="$colon_refs $tok" ;;
              *) dest_refs="$dest_refs $tok" ;;
            esac
          fi
          ;;
      esac
      ;;
  esac
done
finish_segment

exit 0
