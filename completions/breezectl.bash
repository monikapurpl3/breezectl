# bash completion for breezectl.
#
# Needs no bash-completion package, and runs on bash 3.2 (macOS) too. Unit
# names come from `breezectl __complete units`, which reads the list the client
# keeps of the last units it saw, so a Tab does not wait on the network. Names
# are matched case-insensitively, as breezectl matches them.

# Offer the lines of $1 that start with the word being completed.
_breezectl_offer() {
  local item cur=$2 had_nocase=1
  [ -n "$1" ] || return 0
  shopt -q nocasematch || had_nocase=0
  shopt -s nocasematch
  # A quote the word was started with is not part of the name.
  cur=${cur#[\'\"]}
  while IFS= read -r item; do
    [ -n "$item" ] && [[ $item == "$cur"* ]] && COMPREPLY+=("$item")
  done <<<"$1"
  [ "$had_nocase" = 1 ] || shopt -u nocasematch
}

_breezectl_units() { # [--server NAME]
  local list
  list=$(breezectl "$@" __complete units 2>/dev/null)
  _breezectl_offer "$list" "$cur"
  # Names with spaces: quoted as a file name would be, if this bash can.
  if compopt -o filenames 2>/dev/null; then :; else
    local i
    for i in "${!COMPREPLY[@]}"; do COMPREPLY[i]=$(printf '%q' "${COMPREPLY[i]}"); done
  fi
}

_breezectl_words() { _breezectl_offer "$(printf '%s\n' "$@")" "$cur"; }

# File names: readline's own completion where this bash can hand over to it
# (4.0 and later), which gets spaces and quotes right; compgen otherwise.
_breezectl_files() {
  if compopt -o default 2>/dev/null; then COMPREPLY=(); return; fi
  local IFS=$'\n'
  # shellcheck disable=SC2207
  COMPREPLY=($(compgen -f -- "$cur"))
}

_breezectl_slot() {
  case $1 in
    1) _breezectl_words cool heat dry auto fan on off none ;;
    2) _breezectl_words none 18 19 20 21 22 23 24 25 26 ;;
    3) _breezectl_words both horizontal vertical off none ;;
    4) _breezectl_words silent low medium high max auto none ;;
    5) _breezectl_words turbo eco turbo+eco no-turbo no-eco none ;;
    6) _breezectl_words 15m 30m 45m 1h 2h ;;
  esac
}

_breezectl() {
  local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]}
  local -a srv=()
  COMPREPLY=()

  if [ "$prev" = --server ] || [ "$prev" = -s ]; then
    _breezectl_offer "$(breezectl __complete servers 2>/dev/null)" "$cur"
    return
  fi

  # Past the options that come before the command.
  local i=1
  while [ "$i" -lt "$COMP_CWORD" ]; do
    case ${COMP_WORDS[i]} in
      --server | -s) srv=(--server "${COMP_WORDS[i+1]}"); i=$((i + 2)) ;;
      --server=*) srv=(--server "${COMP_WORDS[i]#--server=}"); i=$((i + 1)) ;;
      --) i=$((i + 1)) ;;
      *) break ;;
    esac
  done

  if [ "$i" -ge "$COMP_CWORD" ]; then
    case $cur in
      -*) _breezectl_words --server --help --version ;;
      *)
        _breezectl_words status units timers login logout servers diag nerd version help control
        _breezectl_units "${srv[@]}" ;;
    esac
    return
  fi

  local cmd=${COMP_WORDS[i]} pos=$((COMP_CWORD - i)) sub=${COMP_WORDS[i+1]}
  case $cmd in
    status | st) _breezectl_units "${srv[@]}" ;;
    units | list | diag | doctor | version | help | --help | -h | --version | -V) ;;
    timers | timer)
      if [ "$pos" -eq 1 ]; then _breezectl_words list off start cancel; return; fi
      case $sub in
        off)
          case $pos in 2) _breezectl_units "${srv[@]}" ;; 3) _breezectl_words 15m 30m 45m 1h 2h ;; esac ;;
        start | on)
          case $pos in 2) _breezectl_units "${srv[@]}" ;; 4) _breezectl_words today tomorrow 2 3 4 5 6 7 ;; esac ;;
        cancel | rm | delete)
          if [ "$pos" -eq 2 ]; then _breezectl_words all; _breezectl_units "${srv[@]}"; fi ;;
      esac ;;
    servers | server)
      if [ "$pos" -eq 1 ]; then
        _breezectl_words list use rename remove
      elif [ "$pos" -eq 2 ]; then
        case $sub in use | rename | remove | rm | forget)
          _breezectl_offer "$(breezectl __complete servers 2>/dev/null)" "$cur" ;;
        esac
      fi ;;
    logout | unpair)
      [ "$pos" -eq 1 ] && _breezectl_offer "$(breezectl __complete servers 2>/dev/null)" "$cur" ;;
    login | pair)
      case $prev in
        --ca) _breezectl_files ;;
        --name | --label) ;;
        *) _breezectl_words --name --label --ca --key-stdin --yes ;;
      esac ;;
    nerd)
      [ "$pos" -eq 1 ] && _breezectl_files ;;
    control)
      if [ "$pos" -eq 1 ]; then _breezectl_units "${srv[@]}"; else _breezectl_slot $((pos - 1)); fi ;;
    *)
      # The first word was a unit's name.
      _breezectl_slot "$pos" ;;
  esac
}

complete -F _breezectl breezectl
