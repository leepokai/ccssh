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

# --- choosing a directory ---------------------------------------------------

# The longest prefix every candidate shares.
_ccssh_common_prefix() {
  python3 -c '
import os, sys

lines = [line.rstrip("\n") for line in sys.stdin if line.strip()]
print(os.path.commonprefix(lines) if lines else "")
'
}

# ccssh_pick_folder <host> <home>
#
# One flat list of every directory under the remote home, fetched once, then
# filtered here. Asking the host per directory costs a round trip each time you
# walk into one; asking once costs about a third of a second and makes typing,
# backtracking and jumping somewhere unrelated all free.
#
# There is deliberately no second mode for paths. fzf's own completion walks up
# with dirname until it finds a directory that exists and treats the rest as the
# query — one rule, nothing that changes under you. A single flat list gets the
# same result with no rule at all.
ccssh_pick_folder() {
  local host="$1" home="$2"
  local prompt="Folder on $host: "
  local buffer='' ch rest line i selected=0 total=0 listing
  local -a matches=()

  if ! { exec 3</dev/tty 4>/dev/tty; } 2>/dev/null; then
    printf 'ccssh needs a terminal to choose a folder.\n' >&2
    printf 'Name the directory directly instead, e.g. ccssh %s:/path\n' "$host" >&2
    return 1
  fi

  listing="$(mktemp)"
  status "$host · reading directories"
  ccssh_list_dirs "$host" > "$listing"
  status_clear
  total="$(wc -l < "$listing" | tr -d ' ')"

  _finish() {
    printf '\033[J\n' >&4
    exec 3<&- 4>&-
    rm -f "$listing"
  }

  # $HOME shown as ~, the way lf writes its prompt: the home prefix is on
  # every row and carries no information.
  _short() {
    case "$1" in
      "$home"/*) printf '~/%s' "${1#"$home"/}" ;;
      "$home")   printf '~' ;;
      *)         printf '%s' "$1" ;;
    esac
  }

  _full() {
    case "$1" in
      '~/'*) printf '%s/%s' "$home" "${1#\~/}" ;;
      '~')   printf '%s' "$home" ;;
      *)     printf '%s' "$1" ;;
    esac
  }

  # Where the match landed decides the order, then the shorter path wins —
  # fzf's --scheme=path does the same with --tiebreak=pathname,length.
  # Without this, typing "mycode" reaches a cache directory that merely
  # contains the word before it reaches ~/mycode.
  _rank() {
    awk -v q="$1" -v fold="$2" '
      {
        name = $0
        sub(/.*\//, "", name)
        # A leading dot should not cost a directory its place: typing
        # "config" means ~/.config far more often than some nested src/config.
        bare = name
        sub(/^\./, "", bare)
        needle = fold ? tolower(q) : q
        hay    = fold ? tolower(bare) : bare
        if (index(hay, needle) == 1)  rank = 0    # the name starts with it
        else if (index(hay, needle))  rank = 1    # the name contains it
        else                          rank = 2    # only the path does
        print rank "\t" length($0) "\t" $0
      }
    ' | sort -t "$(printf '\t')" -k1,1n -k2,2n | cut -f3-
  }

  # Insensitive until you type a capital — smart-case, which fzf, lf and yazi
  # all default to. Substring before subsequence, so exact hits lead: without
  # real scoring, unranked fuzzy ranks worse than plain substring.
  _refilter() {
    local needle pattern
    matches=()
    [ -n "$buffer" ] || {
      while IFS= read -r line; do matches+=("$line"); done < "$listing"
      selected=0
      return
    }

    case "$buffer" in
      *[A-Z]*) needle="$buffer"; pattern='' ;;
      *)       needle="$buffer" ;;
    esac

    pattern="$(printf '%s' "$needle" | sed 's/[][\.*^$/]/\\&/g; s/./&.*/g')"
    pattern="${pattern%.\*}"

    case "$buffer" in
      *[A-Z]*)
        while IFS= read -r line; do matches+=("$line"); done \
          < <( { grep -F -- "$needle" "$listing"
                 grep -E -- "$pattern" "$listing" | grep -Fv -- "$needle"; } |
               _rank "$needle" 0 )
        ;;
      *)
        while IFS= read -r line; do matches+=("$line"); done \
          < <( { grep -Fi -- "$needle" "$listing"
                 grep -Ei -- "$pattern" "$listing" | grep -Fvi -- "$needle"; } |
               _rank "$needle" 1 )
        ;;
    esac
    selected=0
  }

  _draw() {
    local width count pad shown
    width="$(tput cols 2>/dev/null || echo 80)"
    count="${#matches[@]}/${total}"
    pad=$(( width - ${#prompt} - ${#buffer} - ${#count} - 4 ))
    [ "$pad" -lt 1 ] && pad=1

    printf '\r\033[2K  %s%s%s%s%*s%s%s%s' \
      "$_c_dim" "$prompt" "$_c_reset" "$buffer" \
      "$pad" '' "$_c_dim" "$count" "$_c_reset" >&4
    printf '\033[s\033[J' >&4

    shown=0
    for i in "${!matches[@]}"; do
      [ "$shown" -ge 8 ] && break
      if [ "$i" -eq "$selected" ]; then
        printf '\n\033[2K  \033[36m>\033[0m \033[1m%s\033[0m' "$(_short "${matches[$i]}")" >&4
      else
        printf '\n\033[2K    %s%s\033[0m' "$_c_dim" "$(_short "${matches[$i]}")" >&4
      fi
      shown=$((shown + 1))
    done
    [ "${#matches[@]}" -gt 8 ] &&
      printf '\n\033[2K    %s%d more\033[0m' "$_c_dim" "$((${#matches[@]} - 8))" >&4
    [ "${#matches[@]}" -eq 0 ] &&
      printf '\n\033[2K    %sno match — Enter takes what you typed\033[0m' "$_c_dim" >&4
    printf '\033[u' >&4
  }

  printf '\n' >&4
  _refilter
  _draw

  while IFS= read -rsn1 -u 3 ch; do
    case "$ch" in
      '')
        [ "${#matches[@]}" -gt 0 ] && buffer="${matches[$selected]}"
        break
        ;;
      $'\177'|$'\b')
        buffer="${buffer%?}"
        _refilter
        ;;
      $'\t')
        # Take the highlighted entry, rather than completing to the prefix the
        # matches share: over a fuzzy result set that prefix is worth nothing —
        # for /usr/local and /var/log it is "/". fzf made the same call.
        if [ "${#matches[@]}" -gt 0 ]; then
          buffer="$(_short "${matches[$selected]}")"
          _refilter
        fi
        ;;
      $'\003'|$'\007')
        _finish; return 130
        ;;
      $'\033')
        IFS= read -rsn2 -t "$CCSSH_ESCAPE_TIMEOUT" -u 3 rest || rest=''
        case "$rest" in
          '[A') [ "${#matches[@]}" -gt 0 ] &&
                  selected=$(( (selected - 1 + ${#matches[@]}) % ${#matches[@]} )) ;;
          '[B') [ "${#matches[@]}" -gt 0 ] &&
                  selected=$(( (selected + 1) % ${#matches[@]} )) ;;
          '')   _finish; return 130 ;;
        esac
        ;;
      *)
        case "$ch" in
          [[:print:]]) buffer="$buffer$ch"; _refilter ;;
          *) continue ;;
        esac
        ;;
    esac
    _draw
  done

  _finish
  # Nothing matched: hand back what was typed and say so, the way fzf's
  # --print-query does, so the caller can tell the difference.
  if [ "${#matches[@]}" -eq 0 ]; then
    printf '%s\n' "$(_full "$buffer")"
    return 1
  fi
  printf '%s\n' "$(_full "$buffer")"
}
