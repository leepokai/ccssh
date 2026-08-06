#!/usr/bin/env bash
# Interactive selection.
#
# fzf is used when present — it brings typing-to-filter and mouse support for
# free. Without it a built-in arrow-key menu keeps ccssh usable with no
# dependencies to install first.

# How long to wait for the rest of an escape sequence. macOS ships bash 3.2,
# whose `read -t` rejects fractional seconds, so there it waits a whole second.
# Arrow keys still feel instant — their remaining bytes have already arrived —
# and only a bare Escape takes that long to register.
if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then
  CCSSH_ESCAPE_TIMEOUT=0.05
else
  CCSSH_ESCAPE_TIMEOUT=1
fi

# ccssh_pick <prompt> <option>...
# Prints the chosen option on stdout. Returns 1 if the user cancels.
ccssh_pick() {
  local prompt="$1"; shift
  local -a options=("$@")
  local count=${#options[@]}

  [ "$count" -gt 0 ] || return 1
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "${options[0]}"
    return 0
  fi

  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "${options[@]}" |
      fzf --prompt="$prompt " --height=~60% --reverse --no-multi --ansi
    return
  fi

  _ccssh_menu "$prompt" "${options[@]}"
}

_ccssh_menu() {
  local prompt="$1"; shift
  local -a options=("$@")
  local count=${#options[@]}
  local selected=0 key rest

  # /dev/tty can exist yet fail to open when there is no controlling terminal,
  # so open it rather than stat it.
  if ! { exec 3</dev/tty 4>/dev/tty; } 2>/dev/null; then
    printf 'ccssh needs a terminal to show the menu.\n' >&2
    printf 'Name the host directly instead, e.g. ccssh mac-mini\n' >&2
    return 1
  fi

  _render() {
    local i
    for i in "${!options[@]}"; do
      if [ "$i" -eq "$selected" ]; then
        printf '\033[2K  \033[36m›\033[0m \033[1m%s\033[0m\n' "${options[$i]}" >&4
      else
        printf '\033[2K    \033[2m%s\033[0m\n' "${options[$i]}" >&4
      fi
    done
  }

  printf '\n  %s\n\n' "$prompt" >&4
  printf '\033[?25l' >&4          # hide the cursor while navigating
  _render

  while IFS= read -rsn1 -u 3 key; do
    case "$key" in
      $'\x1b')
        IFS= read -rsn2 -t "$CCSSH_ESCAPE_TIMEOUT" -u 3 rest || rest=''
        case "$rest" in
          '[A') selected=$(( (selected - 1 + count) % count )) ;;
          '[B') selected=$(( (selected + 1) % count )) ;;
          '')   printf '\033[?25h' >&4; exec 3<&- 4>&-; return 1 ;;  # bare Esc
        esac
        ;;
      '')  break ;;                                                  # Enter
      k)   selected=$(( (selected - 1 + count) % count )) ;;
      j)   selected=$(( (selected + 1) % count )) ;;
      q)   printf '\033[?25h' >&4; exec 3<&- 4>&-; return 1 ;;
    esac
    printf '\033[%dA' "$count" >&4
    _render
  done

  printf '\033[?25h\n' >&4
  exec 3<&- 4>&-
  printf '%s\n' "${options[$selected]}"
}

# ccssh_prompt <question> — free-text input, printed on stdout.
ccssh_prompt() {
  local answer
  printf '\n  %s ' "$1" > /dev/tty
  IFS= read -r answer < /dev/tty || return 1
  printf '%s\n' "$answer"
}

# --- typing a remote path ---------------------------------------------------

# Directories under <dir> on <host>, cached: walking back up a path you have
# already visited should not cost another round trip.
_ccssh_children() {
  local host="$1" dir="$2" file
  file="$_ccssh_path_cache/$(printf '%s' "$dir" | ccssh_sha256 | cut -c1-16)"
  if [ ! -f "$file" ]; then
    # -n keeps ssh from swallowing the keystrokes still queued on stdin.
    ssh -n "$host" "ls -1p $(ccssh_shq "$dir") 2>/dev/null" 2>/dev/null |
      grep '/$' | sed 's|/$||' > "$file" || true
  fi
  cat "$file" 2>/dev/null
}

# The longest prefix every candidate shares, for Tab.
_ccssh_common_prefix() {
  python3 -c '
import os, sys

lines = [line.rstrip("\n") for line in sys.stdin if line.strip()]
print(os.path.commonprefix(lines) if lines else "")
'
}

# ccssh_prompt_path <host> [starting-path]
#
# A path you type, with the remote answering: what you have typed filters the
# directories that actually exist there, Tab completes, and the arrows walk the
# list. The arrows write their choice into the line, so what you see on the
# line is always what you will get.
ccssh_prompt_path() {
  local host="$1" buffer="${2:-/}"
  local prompt="Path on $host: "
  local ch rest dir base line i selected=-1
  local -a matches=()

  if ! { exec 3</dev/tty 4>/dev/tty; } 2>/dev/null; then
    ccssh_prompt "Path on $host:"
    return
  fi

  _ccssh_path_cache="$(mktemp -d)"

  _refilter() {
    dir="${buffer%/*}/"
    base="${buffer##*/}"
    matches=()
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        "$base"*) matches+=("$line") ;;
      esac
    done < <(_ccssh_children "$host" "$dir")
    # Nothing chosen yet: what you typed stands until you move onto a
    # suggestion, so the first press of Down takes the first one.
    selected=-1
  }

  _draw() {
    printf '\r\033[2K  %s%s%s%s' "$_c_dim" "$prompt" "$_c_reset" "$buffer" >&4
    printf '\033[s\033[J' >&4
    for i in "${!matches[@]}"; do
      [ "$i" -ge 8 ] && break
      if [ "$i" -eq "$selected" ]; then
        printf '\n\033[2K      \033[36m>\033[0m \033[1m%s/\033[0m' "${matches[$i]}" >&4
      else
        printf '\n\033[2K        \033[2m%s/\033[0m' "${matches[$i]}" >&4
      fi
    done
    [ "${#matches[@]}" -gt 8 ] &&
      printf '\n\033[2K        \033[2m... %d more\033[0m' "$((${#matches[@]} - 8))" >&4
    printf '\033[u' >&4
  }

  _take_selected() {
    [ "${#matches[@]}" -gt 0 ] || return 1
    buffer="${dir}${matches[$selected]}"
  }

  printf '\n' >&4
  _refilter
  _draw

  while IFS= read -rsn1 -u 3 ch; do
    case "$ch" in
      '')
        break
        ;;
      $'\177'|$'\b')
        buffer="${buffer%?}"
        _refilter
        ;;
      $'\t')
        if [ "${#matches[@]}" -eq 1 ]; then
          buffer="${dir}${matches[0]}/"
        elif [ "${#matches[@]}" -gt 1 ]; then
          line="$(printf '%s\n' "${matches[@]}" | _ccssh_common_prefix)"
          [ -n "$line" ] && buffer="${dir}${line}"
        fi
        _refilter
        ;;
      $'\033')
        IFS= read -rsn2 -t "$CCSSH_ESCAPE_TIMEOUT" -u 3 rest || rest=''
        case "$rest" in
          '[A') if [ "${#matches[@]}" -gt 0 ]; then
                  if [ "$selected" -le 0 ]; then
                    selected=$(( ${#matches[@]} - 1 ))
                  else
                    selected=$(( selected - 1 ))
                  fi
                  _take_selected
                fi ;;
          '[B') [ "${#matches[@]}" -gt 0 ] &&
                  selected=$(( (selected + 1) % ${#matches[@]} )) &&
                  _take_selected ;;
          '')   printf '\033[J\n' >&4; exec 3<&- 4>&-
                rm -rf "$_ccssh_path_cache"; return 1 ;;
        esac
        ;;
      $'\003')
        printf '\033[J\n' >&4; exec 3<&- 4>&-
        rm -rf "$_ccssh_path_cache"; return 1
        ;;
      *)
        # Only what can be typed: a stray Ctrl-D or other control byte landing
        # in the buffer would make it match nothing, invisibly.
        case "$ch" in
          [[:print:]]) buffer="$buffer$ch"; _refilter ;;
          *) continue ;;
        esac
        ;;
    esac
    _draw
  done

  printf '\033[J\n' >&4
  exec 3<&- 4>&-
  rm -rf "$_ccssh_path_cache"
  printf '%s\n' "$buffer"
}
