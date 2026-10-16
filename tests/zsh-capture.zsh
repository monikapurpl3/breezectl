#!/usr/bin/env zsh
# Print what zsh's completion offers for a command line, one match per line:
#
#   FPATH_ADD=completions zsh tests/zsh-capture.zsh 'breezectl kit'
#
# It drives an interactive zsh in a pty, with compadd wrapped to print the
# matches instead of inserting them -- the technique of Valodim's
# zsh-capture-completion, cut down to what these tests need.

zmodload zsh/zpty || { print -u2 'no zsh/zpty'; exit 1 }
zpty z zsh -f -i
local line setup
setup=$(mktemp)
# CAPTURE_RC: a startup file to read first, to test what it sets up;
# otherwise the completions folder ($FPATH_ADD, or ./completions) is added.
if [[ -n ${CAPTURE_RC:-} ]]; then
  first="source ${(q)CAPTURE_RC}"
else
  first="fpath=(${(q)${FPATH_ADD:-$PWD/completions}} \$fpath)"
fi
cat >"$setup" <<EOF
PROMPT=
$first
autoload -Uz compinit
compinit -u -D
bindkey '^M' undefined
bindkey '^J' undefined
bindkey '^I' complete-word
null-line () { echo -E - \$'\\0' }
compprefuncs=( null-line )
comppostfuncs=( null-line exit )
zstyle ':completion:*' list-grouped false
zstyle ':completion:*' insert-tab false
zmodload zsh/zutil
compadd () {
  if [[ \${@[1,(i)(-|--)]} == *-(O|A|D)\\ * ]]; then builtin compadd "\$@"; return \$?; fi
  typeset -a __hits
  builtin compadd -A __hits "\$@"
  [[ -n \$__hits ]] || return
  local h
  for h in \$__hits; do echo -E - "\$h"; done
}
echo ok
EOF
zpty -w z "source $setup"
repeat 4; do
  zpty -r z line
  [[ $line == ok* ]] && break
done
zpty -w z "$1"$'\t'
integer tog=0
while zpty -r z; do :; done | while IFS= read -r line; do
  if [[ $line == *$'\0\r' ]]; then
    (( tog++ )) && break || continue
  fi
  (( tog )) && print -r -- "${line%$'\r'}"
done
rm -f "$setup"
