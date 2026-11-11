#!/usr/bin/env bash
# File operations inside a user's home, run AS that user (never as root).
#
# agent/lib/host.sh calls this through runuser, so every read and write in the home has the
# user's own permissions: a symlink the user plants (~/.bashrc -> /etc/shadow,
# ~/.config/docker -> /etc/docker) cannot make root read or change a system file.
# Symlinks below HOME are refused on top of that, so setup never works on a redirected path.
#
#   user-file.sh mkdir HOME DIR MODE                  create DIR (parent must exist), enforce MODE
#   user-file.sh put   HOME FILE MODE < content       write FILE if different, enforce MODE
#   user-file.sh block HOME FILE MARKER top|bottom < block
#                                                     keep one copy of a "# >>> MARKER" block
#   user-file.sh test  HOME -e|-f|-d|-x PATH          file test; only PATH itself may be a
#                                                     symlink (e.g. ~/.local/bin/hermes)
#
# Prints "changed: ..." or "ok: ...". Exit codes: 0 = changed (test: true),
# 1 = unchanged (test: false), 3 = refused / error.
set -euo pipefail
export LC_ALL=C
umask 022

refuse() { echo "ERROR: $*" >&2; exit 3; }

(($(id -u) != 0)) || refuse "user-file.sh must not run as root"
(($# >= 3)) || refuse "usage: user-file.sh mkdir|put|block|test HOME ..."

# check_path HOME PATH [final-link-ok]: PATH is a canonical path below HOME and no component
# is a symlink (with final-link-ok: except PATH itself).
check_path() {
  local home="$1" path="$2" final_ok="${3:-}" rel p part parts i
  [[ "$home" == /?* && "$home" != */ ]] || refuse "bad home directory: $home"
  [[ "$path" == "$home"/?* ]] || refuse "$path is not below $home"
  case "$path/" in
    *//* | */./* | */../*) refuse "$path is not a canonical path" ;;
  esac
  [[ ! -L "$home" ]] || refuse "$home is a symlink; not following it"
  [[ -d "$home" ]] || refuse "$home is not a directory"
  rel="${path#"$home"/}"
  p="$home"
  IFS=/ read -ra parts <<< "$rel"
  for ((i = 0; i < ${#parts[@]}; i++)); do
    part="${parts[i]}"
    p="$p/$part"
    [[ -n "$final_ok" ]] && ((i == ${#parts[@]} - 1)) && break
    [[ ! -L "$p" ]] || refuse "$p is a symlink; not following it"
  done
}

check_mode() {
  [[ "$1" =~ ^0?[0-7]{3}$ ]] || refuse "bad mode: $1"
}

TMP_FILE=""
trap '[[ -z "$TMP_FILE" ]] || rm -f "$TMP_FILE"' EXIT

op_mkdir() {
  local path="$1" mode="$2"
  check_mode "$mode"
  if [[ -e "$path" ]]; then
    [[ -d "$path" ]] || refuse "$path exists and is not a directory"
    if [[ "$(stat -c %a "$path")" != "${mode#0}" ]]; then
      chmod "$mode" "$path"
      echo "changed: $path (mode $mode)"
      return 0
    fi
    echo "ok: $path"
    return 1
  fi
  [[ -d "$(dirname "$path")" ]] || refuse "missing parent directory of $path"
  mkdir -m "$mode" "$path"
  echo "changed: $path"
  return 0
}

op_put() {
  local path="$1" mode="$2" dir
  check_mode "$mode"
  dir="$(dirname "$path")"
  [[ -d "$dir" ]] || refuse "missing directory $dir"
  [[ ! -e "$path" || -f "$path" ]] || refuse "$path exists and is not a regular file"
  # errexit is off when the caller uses "|| true": check every step explicitly
  TMP_FILE="$(mktemp "$dir/.adk-tmp.XXXXXX")" || refuse "cannot create a file in $dir"
  cat > "$TMP_FILE" || refuse "cannot write $TMP_FILE"
  if [[ -f "$path" ]] && cmp -s "$TMP_FILE" "$path" && [[ "$(stat -c %u "$path")" == "$(id -u)" ]]; then
    rm -f "$TMP_FILE"
    TMP_FILE=""
    if [[ "$(stat -c %a "$path")" != "${mode#0}" ]]; then
      chmod "$mode" "$path"
      echo "changed: $path (mode $mode)"
      return 0
    fi
    echo "ok: $path"
    return 1
  fi
  chmod "$mode" "$TMP_FILE" || refuse "cannot chmod $TMP_FILE"
  # rename: replaces the directory entry itself, never writes through it
  mv -f "$TMP_FILE" "$path" || refuse "cannot write $path"
  TMP_FILE=""
  echo "changed: $path"
  return 0
}

op_block() {
  local path="$1" marker="$2" pos="$3" block existing="" rest=""
  [[ "$pos" == top || "$pos" == bottom ]] || refuse "position must be top or bottom"
  [[ -n "$marker" && "$marker" != *$'\n'* ]] || refuse "bad marker"
  block="$(printf '# >>> %s\n%s\n# <<< %s' "$marker" "$(cat)" "$marker")"
  if [[ -e "$path" ]]; then
    [[ -f "$path" ]] || refuse "$path exists and is not a regular file"
    existing="$(awk -v b="# >>> $marker" -v e="# <<< $marker" '$0 == b {p = 1} p {print} $0 == e {p = 0}' "$path")"
    rest="$(awk -v b="# >>> $marker" -v e="# <<< $marker" '$0 == b {s = 1; next} $0 == e {s = 0; next} !s' "$path")"
  fi
  if [[ "$existing" == "$block" ]]; then
    echo "ok: $path ($marker)"
    return 1
  fi
  # Here-strings, not pipes: op_put must run in this shell (refusals exit, temp file trap).
  if [[ "$pos" == top ]]; then
    op_put "$path" 0644 <<< "$block"$'\n'"$rest" > /dev/null || true
  else
    op_put "$path" 0644 <<< "$rest"$'\n'"$block" > /dev/null || true
  fi
  echo "changed: $path ($marker)"
  return 0
}

op_test() {
  local flag="$1" path="$2"
  case "$flag" in
    -e) [[ -e "$path" ]] ;;
    -f) [[ -f "$path" ]] ;;
    -d) [[ -d "$path" ]] ;;
    -x) [[ -x "$path" ]] ;;
    *) refuse "unsupported test $flag" ;;
  esac
}

op="$1" home="$2"
shift 2
case "$op" in
  mkdir) (($# == 2)) || refuse "usage: mkdir HOME DIR MODE"; check_path "$home" "$1"; op_mkdir "$1" "$2" ;;
  put) (($# == 2)) || refuse "usage: put HOME FILE MODE"; check_path "$home" "$1"; op_put "$1" "$2" ;;
  block) (($# == 3)) || refuse "usage: block HOME FILE MARKER top|bottom"; check_path "$home" "$1"; op_block "$1" "$2" "$3" ;;
  test)
    (($# == 2)) || refuse "usage: test HOME FLAG PATH"
    check_path "$home" "$2" final-link-ok
    op_test "$1" "$2"
    ;;
  *) refuse "unknown operation: $op" ;;
esac
