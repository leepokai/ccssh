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
