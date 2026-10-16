#!/bin/sh
# Tests for install.sh, as root in a throwaway Debian container with zsh,
# bash, fish and dash:
#
#   sh stage.sh --dirty /tmp/dist
#   docker run --rm -v ...:/w breezectl-shells sh /w/tests/install-unix.sh /dist
#
# For each login shell it makes a user, gives them startup files worth
# keeping (one a symlink into a dotfiles folder, one without a final
# newline), installs, checks that a new shell finds breezectl and completes
# it, installs again (nothing may change), uninstalls (everything must come
# back), and does the same for root's system-wide install.

# The checks are strings for eval, which ShellCheck cannot see into.
# shellcheck disable=SC2034
set -u
DIST=${1:?usage: install-unix.sh DIST}
W=$(cd "$(dirname "$0")/.." && pwd)
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

as() { u=$1; shift; su - "$u" -c "$*" 2>&1; }
snap() { for f in "$@"; do if [ -e "$f" ]; then sha256sum <"$f" | cut -c1-16; else echo none; fi; done | tr '\n' ' '; }

for sh in zsh bash fish dash; do
  u=u_$sh
  useradd -m -s "$(command -v "$sh")" "$u"
  h=/home/$u
  # Startup files worth keeping. zsh's is a symlink into a dotfiles folder
  # and has no final newline.
  if [ "$sh" = zsh ]; then
    mkdir -p "$h/dotfiles"
    printf '# my zshrc, Čajna\nautoload -Uz compinit && compinit -u\nalias ll="ls -l"' >"$h/dotfiles/zshrc"
    ln -s dotfiles/zshrc "$h/.zshrc"
  fi
  [ "$sh" = fish ] && mkdir -p "$h/.config/fish" && printf 'set -g fish_greeting\n' >"$h/.config/fish/config.fish"
  chown -R "$u:$u" "$h"
  rcs="$h/.zshrc $h/.bashrc $h/.bash_profile $h/.profile $h/.config/fish/conf.d/breezectl.fish"
  before=$(snap $rcs)

  out=$(as "$u" "sh $W/install.sh --from $DIST --no-login")
  check "$sh: install says installed" 'printf "%s" "$out" | grep -q "^Installed breezectl 1"'
  check "$sh: binary in ~/.local/bin" '[ -x "$h/.local/bin/breezectl" ]'
  check "$sh: binary owned by the user" '[ "$(stat -c %U "$h/.local/bin/breezectl")" = "$u" ]'
  case $sh in
    zsh)
      check "zsh: .zshrc is still a symlink" '[ -L "$h/.zshrc" ]'
      check "zsh: the block went into the dotfile" 'grep -q "^# >>> breezectl >>>" "$h/dotfiles/zshrc"'
      check "zsh: the old content is all still there" 'head -n 3 "$h/dotfiles/zshrc" | grep -q "alias ll"'
      check "zsh: a new shell finds breezectl" '[ "$(as "$u" "zsh -i -c \"command -v breezectl\"" | tail -n 1)" = "$h/.local/bin/breezectl" ]'
      comp=$(as "$u" "CAPTURE_RC=\$HOME/.zshrc zsh $W/tests/zsh-capture.zsh 'breezectl ti'" | tr -d '\r' | tr '\n' ' ')
      check "zsh: completion works in a new shell ($comp)" 'printf "%s" "$comp" | grep -q "timers"'
      check "zsh: backup kept" '[ -f "$h/.zshrc.breezectl-backup" ]' ;;
    bash)
      check "bash: .bashrc has the block" 'grep -q "^# >>> breezectl >>>" "$h/.bashrc"'
      check "bash: a new interactive shell finds breezectl" '[ "$(as "$u" "bash -i -c \"command -v breezectl\"" 2>/dev/null | tail -n 1)" = "$h/.local/bin/breezectl" ]'
      check "bash: completion registered" 'as "$u" "bash -i -c \"complete -p breezectl\"" | grep -q "_breezectl"' ;;
    fish)
      check "fish: conf.d file" '[ -f "$h/.config/fish/conf.d/breezectl.fish" ]'
      check "fish: a new shell finds breezectl" '[ "$(as "$u" "fish -c \"command -v breezectl\"" | tail -n 1)" = "$h/.local/bin/breezectl" ]'
      check "fish: completion works" 'as "$u" "fish -c \"complete -C \\\"breezectl ti\\\"\"" | grep -q "^timers"' ;;
    dash)
      check "dash: .profile has the block" 'grep -q "^# >>> breezectl >>>" "$h/.profile"'
      check "dash: a new login shell finds breezectl" '[ "$(as "$u" "command -v breezectl" | tail -n 1)" = "$h/.local/bin/breezectl" ]' ;;
  esac

  after=$(snap $rcs)
  out=$(as "$u" "sh $W/install.sh --from $DIST --no-login")
  check "$sh: installing again changes no startup file" '[ "$(snap $rcs)" = "$after" ]'
  check "$sh: and says so" 'printf "%s" "$out" | grep -qE "already (has it|on PATH)"'

  out=$(as "$u" "sh $W/install.sh --uninstall")
  check "$sh: uninstall removes the binary" '[ ! -e "$h/.local/bin/breezectl" ]'
  now=$(snap $rcs)
  if [ "$sh" = zsh ]; then
    # The one thing that may differ: a final newline the file lacked.
    check "zsh: uninstall gives the file back, plus a final newline" \
      '[ "$(cat "$h/dotfiles/zshrc")" = "$(printf "# my zshrc, Čajna\nautoload -Uz compinit && compinit -u\nalias ll=\"ls -l\"")" ]'
    check "zsh: still a symlink" '[ -L "$h/.zshrc" ]'
  else
    check "$sh: uninstall gives every startup file back byte for byte" '[ "$now" = "$before" ]'
  fi
  check "$sh: no completion files left" '[ -z "$(find "$h/.local" "$h/.config" -name "*breezectl*" 2>/dev/null)" ]'
done

# --- root: system-wide, and no startup file touched
before=$(snap /root/.bashrc /root/.profile /root/.zshrc)
out=$(sh "$W/install.sh" --from "$DIST" --no-login 2>&1)
check "root: /usr/local/bin" '[ -x /usr/local/bin/breezectl ]'
check "root: zsh completion in site-functions" '[ -f /usr/local/share/zsh/site-functions/_breezectl ]'
check "root: bash completion" '[ -f /usr/local/share/bash-completion/completions/breezectl ]'
# Where this fish looks: Debian's searches /etc/fish, not /usr/local/share.
check "root: fish completion where fish looks" '[ -f /etc/fish/completions/breezectl.fish ] || [ -f /usr/local/share/fish/vendor_completions.d/breezectl.fish ]'
check "root: no startup file touched" '[ "$(snap /root/.bashrc /root/.profile /root/.zshrc)" = "$before" ]'
comp=$(FPATH_ADD=/nonexistent zsh "$W/tests/zsh-capture.zsh" 'breezectl ti' 2>/dev/null | tr '\n' ' ')
check "root: zsh finds the completion on its own ($comp)" 'printf "%s" "$comp" | grep -q timers'
check "root: fish finds it on its own" 'fish -c "complete -C \"breezectl ti\"" | grep -q "^timers"'
sh "$W/install.sh" --uninstall >/dev/null 2>&1
check "root: uninstall" '[ ! -e /usr/local/bin/breezectl ] && [ ! -e /usr/local/share/zsh/site-functions/_breezectl ] && [ ! -e /etc/fish/completions/breezectl.fish ]'

# --- a download that does not match installs nothing
cp -r "$DIST" /tmp/bad && printf '# tampered\n' >>/tmp/bad/breezectl
out=$(sh "$W/install.sh" --from /tmp/bad --no-login 2>&1)
check "tampered: refused" 'printf "%s" "$out" | grep -q "does not match its checksum"'
check "tampered: nothing installed" '[ ! -e /usr/local/bin/breezectl ]'

# --- dry run
useradd -m -s /usr/bin/zsh u_dry
before=$(snap /home/u_dry/.zshrc /home/u_dry/.profile /home/u_dry/.bashrc)
out=$(as u_dry "sh $W/install.sh --from $DIST --dry-run")
check "dry run: nothing installed" '[ ! -e /home/u_dry/.local/bin/breezectl ]'
check "dry run: no startup file changed" '[ "$(snap /home/u_dry/.zshrc /home/u_dry/.profile /home/u_dry/.bashrc)" = "$before" ]'
check "dry run: says what it would do" 'printf "%s" "$out" | grep -q "would add to"'

# --- piped, as curl | sh runs it
useradd -m -s /bin/bash u_pipe
out=$(su - u_pipe -c "sh -s -- --from $DIST --no-login" <"$W/install.sh" 2>&1)
check "piped: installs" '[ -x /home/u_pipe/.local/bin/breezectl ]'
out=$(su - u_pipe -c "sh -s -- --help" <"$W/install.sh" 2>&1)
check "piped: --help still says something" 'printf "%s" "$out" | grep -q -- "--uninstall"'

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
