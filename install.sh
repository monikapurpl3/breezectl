#!/bin/sh
# install.sh -- install breezectl, then pair it with a Breeze Core server.
#
#   curl -fsSL https://aspic.salataputarica.hr.eu.org/breezectl/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --no-login
#   sh install.sh --uninstall
#
# What it does, and nothing more:
#   * downloads breezectl and its tab completions, and checks each one against
#     SHA256SUMS before anything is installed;
#   * installs them: for a user in ~/.local/bin and ~/.local/share; for root
#     in /usr/local; on Termux in $PREFIX;
#   * makes `breezectl` findable. When its directory is not on PATH, or zsh or
#     bash need telling where the completions are, it adds a marked block to
#     your shell's startup file -- zsh, bash, sh/ksh, fish -- and says which.
#     It only ever adds that block (or replaces its own), keeps a copy of the
#     file as FILE.breezectl-backup, and --uninstall takes the block out again;
#   * runs `breezectl login`, the pairing wizard, if there is a terminal.
#
# Options (after `sh -s --` when piped):
#   --bin DIR        install breezectl there instead
#   --from URL|DIR   where to fetch the files from (default: aspic)
#   --url ADDRESS    the server to pair with, so the wizard need not ask
#   --no-rc          do not touch any shell startup file; say what to add
#   --no-login       do not run the pairing wizard
#   --dry-run        say what would be done, and do none of it
#   --uninstall      remove breezectl, its completions and its blocks
#
# Copyright 2026 Monika. AGPL-3.0-or-later; see LICENSE.

# Everything is in functions, and main runs on the last line: run as
# `curl | sh`, the shell reads this file as it arrives, so nothing may run
# before all of it has -- a cut-off download then does nothing at all.

say() { printf '%s\n' "$*"; }
warn() { printf 'breezectl install: %s\n' "$*" >&2; }
die() { warn "$@"; exit 1; }

DEFAULT_FROM=https://aspic.salataputarica.hr.eu.org/breezectl
BEGIN_MARK='# >>> breezectl >>>'
END_MARK='# <<< breezectl <<<'
FILES="breezectl completions/_breezectl completions/breezectl.bash completions/breezectl.fish"

# ------------------------------------------------------------------ where

layout() {
  if [ -n "${TERMUX_VERSION:-}" ] || case "${PREFIX:-}" in *com.termux*) true ;; *) false ;; esac; then
    MODE=system KIND=Termux
    BIN=${OPT_BIN:-$PREFIX/bin} SHARE=$PREFIX/share
  elif [ "$(id -u 2>/dev/null)" = 0 ]; then
    MODE=system KIND=root
    BIN=${OPT_BIN:-/usr/local/bin} SHARE=/usr/local/share
  else
    MODE=user KIND=user
    [ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME is not set to a directory"
    BIN=${OPT_BIN:-${XDG_BIN_HOME:-$HOME/.local/bin}}
    SHARE=${XDG_DATA_HOME:-$HOME/.local/share}
  fi
  BIN=${BIN%/}
  case "$BIN" in /*) ;; *) BIN="$(pwd)/$BIN" ;; esac
  # It goes into startup files between double quotes.
  case "$BIN$SHARE" in
    *[\"\$\`\\]* | *"
"*) die "the install directory may not contain quotes, \$, backquotes or backslashes: $BIN" ;;
  esac
  if [ "$MODE" = system ]; then
    ZSH_DIR=$SHARE/zsh/site-functions
    BASH_FILE=$SHARE/bash-completion/completions/breezectl
    FISH_FILE=$SHARE/fish/vendor_completions.d/breezectl.fish
  else
    ZSH_DIR=$SHARE/breezectl/zsh
    BASH_FILE=$SHARE/bash-completion/completions/breezectl
    FISH_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions/breezectl.fish
  fi
  # Where fish looks differs by build: Debian's searches only its own
  # /usr/share for vendor completions. Asked, when fish is here.
  if [ "$MODE" = system ] && command -v fish >/dev/null 2>&1; then
    fish_path=$(fish -c 'string join \n $fish_complete_path' 2>/dev/null </dev/null)
    for d in "$SHARE/fish/vendor_completions.d" /etc/fish/completions /usr/local/etc/fish/completions; do
      if printf '%s\n' "$fish_path" | grep -qxF "$d"; then FISH_FILE=$d/breezectl.fish; break; fi
    done
  fi
  FISH_CONF=${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/fish/conf.d/breezectl.fish
  CONF_DIR=${BREEZECTL_CONFIG:-${XDG_CONFIG_HOME:-${HOME:-.}/.config}/breezectl}
  ZRC=${ZDOTDIR:-${HOME:-/nonexistent}}/.zshrc
}

# A path as the startup files should spell it: under $HOME, through $HOME,
# so a renamed or synced home still works.
spell() {
  case "$1" in
    "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

on_path() { case ":${PATH:-}:" in *":$1:"* | *":$1/:"*) true ;; *) false ;; esac; }

# Whether an earlier install added the PATH line: then BIN may be on PATH
# only because of it, and a reinstall must keep it.
had_path_line() {
  for f in "$ZRC" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    [ -f "$f" ] || continue
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
      $0 == b { inb = 1; next }
      $0 == e { inb = 0 }
      inb && index($0, "PATH=\"${PATH}:") { found = 1 }
      END { exit !found }' "$f" && return 0
  done
  [ -f "$FISH_CONF" ]
}

login_shell() { s=${SHELL:-}; printf '%s' "${s##*/}"; }

# --------------------------------------------------------------- fetching

fetch() { # RELATIVE-PATH DESTINATION
  case "$FROM" in
    https://*)
      curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 15 -o "$2" "$FROM/$1" </dev/null ;;
    http://*)
      curl -fsSL --retry 2 --connect-timeout 15 -o "$2" "$FROM/$1" </dev/null ;;
    *)
      cp "$FROM/$1" "$2" ;;
  esac
}

# From standard input, never a file name: GNU sha256sum escapes its whole line
# with a leading backslash when the name holds one (D:\a\_temp/... on a
# Windows runner), and the hash would then start with it.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum <"$1" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 <"$1" | cut -d ' ' -f 1
  elif command -v sha256 >/dev/null 2>&1; then sha256 -q "$1"
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 <"$1" | sed 's/^.*= *//'
  else return 1
  fi
}

download() {
  case "$FROM" in
    http://*) warn "fetching over plain HTTP: the checksums can only catch a broken download, not a tampered one" ;;
  esac
  say "Fetching breezectl from $FROM ..."
  fetch SHA256SUMS "$TMP/SHA256SUMS" || die "cannot fetch $FROM/SHA256SUMS"
  sha256_of "$TMP/SHA256SUMS" >/dev/null ||
    die "this system has no sha256sum, shasum, sha256 or openssl to check the download with"
  for f in $FILES; do
    mkdir -p "$TMP/files/$(dirname "$f")"
    fetch "$f" "$TMP/files/$f" || die "cannot fetch $FROM/$f"
    want=$(awk -v f="$f" '$2 == f || $2 == "*" f { print $1; exit }' "$TMP/SHA256SUMS")
    [ -n "$want" ] || die "SHA256SUMS does not list $f"
    got=$(sha256_of "$TMP/files/$f")
    [ "$got" = "$want" ] || die "$f does not match its checksum -- not installed (expected $want, got $got)"
  done
  say "All $(printf '%s\n' $FILES | wc -l | tr -d ' ') files match their checksums."
}

# ------------------------------------------------------------- installing

put_file() { # SOURCE DESTINATION MODE
  if [ -n "$DRY" ]; then say "  would install $2"; return 0; fi
  mkdir -p "$(dirname "$2")" || die "cannot create $(dirname "$2")"
  cp "$1" "$2.partial" && chmod "$3" "$2.partial" && mv -f "$2.partial" "$2" ||
    { rm -f "$2.partial"; die "cannot write $2"; }
  say "  installed $2"
}

fix_shebang() {
  [ "$KIND" = Termux ] || return 0
  [ -n "$DRY" ] && return 0
  # Termux has no /bin/sh of its own.
  if command -v termux-fix-shebang >/dev/null 2>&1; then
    termux-fix-shebang "$BIN/breezectl"
  else
    sed "1s|^#!/bin/sh|#!$PREFIX/bin/sh|" "$BIN/breezectl" >"$BIN/breezectl.partial" &&
      chmod 755 "$BIN/breezectl.partial" && mv -f "$BIN/breezectl.partial" "$BIN/breezectl"
  fi
}

has_fish() { command -v fish >/dev/null 2>&1 || [ -d "${FISH_CONF%/conf.d/*}" ]; }

install_files() {
  say "Installing:"
  put_file "$TMP/files/breezectl" "$BIN/breezectl" 755
  fix_shebang
  put_file "$TMP/files/completions/_breezectl" "$ZSH_DIR/_breezectl" 644
  put_file "$TMP/files/completions/breezectl.bash" "$BASH_FILE" 644
  if [ "$MODE" = system ] || has_fish; then
    put_file "$TMP/files/completions/breezectl.fish" "$FISH_FILE" 644
  fi
}

# --------------------------------------------------------- startup files
#
# One block per file, between the two marker lines. Writing goes through
# `cat >`, not a rename, so a startup file that is a symlink into a dotfiles
# repository stays one, and keeps its owner and mode.

strip_block() { # FILE -> the file without our block (and the blank line before it)
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    skip { if ($0 == e) skip = 0; next }
    $0 == b { skip = 1; held = 0; next }
    held { print ""; held = 0 }
    $0 == "" { held = 1; next }
    { print }
    END { if (held) print "" }' "$1"
}

show_lines() { # FILE BODY -- for when the file cannot or may not be written
  say "  Add these lines to $1 yourself:"
  printf '%s\n' "$2" | sed 's/^/      /'
}

put_block() { # FILE BODY
  pb_file=$1 pb_body=$2
  if [ -n "$NO_RC" ]; then show_lines "$pb_file" "$pb_body"; return 0; fi
  if [ -e "$pb_file" ] && [ ! -f "$pb_file" ]; then
    warn "$pb_file is not a regular file; left alone"; show_lines "$pb_file" "$pb_body"; return 0
  fi
  if [ -f "$pb_file" ]; then strip_block "$pb_file" >"$TMP/rc.kept" || return 1; else : >"$TMP/rc.kept"; fi
  {
    cat "$TMP/rc.kept"
    [ -s "$TMP/rc.kept" ] && printf '\n'
    printf '%s\n' "$BEGIN_MARK"
    printf '%s\n' "# Added by the breezectl installer. Remove this block, or run the"
    printf '%s\n' "# installer with --uninstall, to undo."
    printf '%s\n' "$pb_body"
    printf '%s\n' "$END_MARK"
  } >"$TMP/rc.new"
  if [ -f "$pb_file" ] && cmp -s "$TMP/rc.new" "$pb_file"; then
    say "  $pb_file already has it"; return 0
  fi
  if [ -n "$DRY" ]; then say "  would add to $pb_file:"; printf '%s\n' "$pb_body" | sed 's/^/      /'; return 0; fi
  if [ -f "$pb_file" ]; then
    if [ ! -w "$pb_file" ]; then warn "$pb_file is not writable; left alone"; show_lines "$pb_file" "$pb_body"; return 0; fi
    cp -p "$pb_file" "$pb_file.breezectl-backup" 2>/dev/null || cp "$pb_file" "$pb_file.breezectl-backup" ||
      { warn "cannot back up $pb_file; left alone"; show_lines "$pb_file" "$pb_body"; return 0; }
    cat "$TMP/rc.new" >"$pb_file" || die "writing $pb_file failed -- the original is in $pb_file.breezectl-backup"
    say "  added to $pb_file (the file as it was: $pb_file.breezectl-backup)"
  else
    if ! { mkdir -p "$(dirname "$pb_file")" && cat "$TMP/rc.new" >"$pb_file"; } 2>/dev/null; then
      warn "cannot create $pb_file"; show_lines "$pb_file" "$pb_body"; return 0
    fi
    say "  created $pb_file"
  fi
  CHANGED_RC=1
}

drop_block() { # FILE
  [ -f "$1" ] || return 0
  grep -qxF "$BEGIN_MARK" "$1" || return 0
  strip_block "$1" >"$TMP/rc.kept" || return 0
  if [ -n "$DRY" ]; then say "  would take the breezectl block out of $1"; return 0; fi
  cp -p "$1" "$1.breezectl-backup" 2>/dev/null || cp "$1" "$1.breezectl-backup" || { warn "cannot back up $1; left alone"; return 0; }
  cat "$TMP/rc.kept" >"$1" && say "  took the breezectl block out of $1 (the file as it was: $1.breezectl-backup)"
}

setup_shells() {
  if [ "$MODE" = system ]; then
    on_path "$BIN" || warn "$BIN is not on PATH; run breezectl as $BIN/breezectl, or add it to PATH"
    return 0
  fi
  sh_login=$(login_shell)
  need_path=""
  on_path "$BIN" || need_path=1
  [ -z "$need_path" ] && had_path_line && need_path=1
  P=$(spell "$BIN")
  path_line="case \":\${PATH}:\" in *\":$P:\"*) ;; *) PATH=\"\${PATH}:$P\"; export PATH ;; esac"
  CHANGED_RC=""
  say "Shell setup:"

  # zsh: the completion's directory, and compdef for a compinit already run.
  if [ "$sh_login" = zsh ] || [ -f "$ZRC" ]; then
    zbody="fpath=(\"$(spell "$ZSH_DIR")\" \$fpath)
if (( \${+functions[compdef]} )); then autoload -Uz _breezectl && compdef _breezectl breezectl; fi"
    [ -n "$need_path" ] && zbody="$path_line
$zbody"
    put_block "$ZRC" "$zbody"
  fi

  # bash: interactive shells read .bashrc; login shells .bash_profile (macOS,
  # ssh), falling back to .profile.
  if [ "$sh_login" = bash ] || [ -f "$HOME/.bashrc" ]; then
    bbody="[ -r \"$(spell "$BASH_FILE")\" ] && . \"$(spell "$BASH_FILE")\""
    [ -n "$need_path" ] && bbody="$path_line
$bbody"
    put_block "$HOME/.bashrc" "$bbody"
  fi
  bash_login_file=""
  if [ "$sh_login" = bash ]; then
    if [ -f "$HOME/.bash_profile" ]; then bash_login_file=$HOME/.bash_profile
    elif [ -f "$HOME/.bash_login" ]; then bash_login_file=$HOME/.bash_login
    fi
  fi
  if [ -n "$need_path" ] && [ -n "$bash_login_file" ]; then put_block "$bash_login_file" "$path_line"; fi

  # sh, dash, ksh, mksh ...: .profile, read by login shells.
  if [ -n "$need_path" ]; then
    case "$sh_login" in
      sh | dash | ash | ksh | ksh93 | mksh | oksh | pdksh | yash | posh) put_block "$HOME/.profile" "$path_line" ;;
      bash) [ -z "$bash_login_file" ] && put_block "$HOME/.profile" "$path_line" ;;
      *) [ -f "$HOME/.profile" ] && put_block "$HOME/.profile" "$path_line" ;;
    esac
  fi

  # fish: a file of its own in conf.d -- nothing to edit.
  if [ -n "$need_path" ] && { [ "$sh_login" = fish ] || has_fish; }; then
    fbody="# Added by the breezectl installer: delete this file, or run the installer
# with --uninstall, to undo.
contains -- \"$P\" \$PATH; or set -gx PATH \$PATH \"$P\""
    if [ -n "$NO_RC" ]; then show_lines "$FISH_CONF" "$fbody"
    elif [ -n "$DRY" ]; then say "  would create $FISH_CONF"
    elif [ -f "$FISH_CONF" ] && [ "$(cat "$FISH_CONF")" = "$fbody" ]; then say "  $FISH_CONF already has it"
    elif mkdir -p "$(dirname "$FISH_CONF")" && printf '%s\n' "$fbody" >"$FISH_CONF"; then say "  created $FISH_CONF"; CHANGED_RC=1
    else warn "cannot create $FISH_CONF"; show_lines "$FISH_CONF" "$fbody"
    fi
  fi

  if [ -z "$need_path" ]; then say "  $BIN is already on PATH."
  elif [ -n "$CHANGED_RC" ]; then say "  New terminals will find breezectl. In this one, until then: $BIN/breezectl"
  fi
}

# -------------------------------------------------------------- uninstall

uninstall() {
  say "Removing breezectl:"
  for f in "$BIN/breezectl" "$ZSH_DIR/_breezectl" "$BASH_FILE" "$FISH_FILE" "$FISH_CONF"; do
    [ -e "$f" ] || continue
    if [ -n "$DRY" ]; then say "  would remove $f"; else rm -f "$f" && say "  removed $f"; fi
  done
  if [ "$MODE" = user ]; then
    rmdir "$ZSH_DIR" "$SHARE/breezectl" 2>/dev/null
    for f in "$ZRC" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do drop_block "$f"; done
  fi
  if [ -d "$CONF_DIR/servers" ] && [ -n "$(ls "$CONF_DIR/servers" 2>/dev/null)" ]; then
    say ""
    say "Kept your saved logins in $CONF_DIR. Each is a device token that stays"
    say "valid on its server until it is revoked: revoke it in the server's web panel,"
    say "or reinstall and run breezectl logout NAME. Then delete that directory."
  fi
}

# ------------------------------------------------------------------ login

tty_ok() { (true </dev/tty) 2>/dev/null && (true >/dev/tty) 2>/dev/null; }

pair() {
  [ -z "$NO_LOGIN" ] && [ -z "$DRY" ] || return 0
  saved=$("$BIN/breezectl" __complete servers 2>/dev/null)
  if [ -n "$saved" ] && [ -z "$OPT_URL" ]; then
    say "Already paired with: $(printf '%s\n' "$saved" | tr '\n' ' ')"
    say "To pair with another server: breezectl login"
    return 0
  fi
  if ! tty_ok; then
    say "No terminal to ask questions in. Pair this machine when ready: breezectl login"
    return 0
  fi
  say ""
  "$BIN/breezectl" login ${OPT_URL:+"$OPT_URL"} </dev/tty ||
    say "Not paired yet. Run breezectl login when ready."
}

# ------------------------------------------------------------------- main

usage() {
  # Piped (curl | sh), there is no file to read the comment from.
  if [ -f "$0" ] && head -n 2 "$0" | grep -q 'breezectl'; then
    sed -n '3,31p' "$0" | sed 's/^# \{0,1\}//'
  else
    say "Options: --bin DIR, --from URL|DIR, --url ADDRESS, --no-rc, --no-login, --dry-run, --uninstall"
    say "They are explained at the top of $DEFAULT_FROM/install.sh"
  fi
}

main() {
  set -u
  umask 022
  OPT_BIN=${BREEZECTL_BIN:-} FROM=${BREEZECTL_FROM:-$DEFAULT_FROM} OPT_URL=""
  NO_RC="" NO_LOGIN="" DRY="" UNINSTALL=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bin) [ "$#" -ge 2 ] || die "--bin needs a directory"; OPT_BIN=$2; shift 2 ;;
      --from) [ "$#" -ge 2 ] || die "--from needs a URL or a directory"; FROM=$2; shift 2 ;;
      --url) [ "$#" -ge 2 ] || die "--url needs an address"; OPT_URL=$2; shift 2 ;;
      --no-rc) NO_RC=1; shift ;;
      --no-login) NO_LOGIN=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --uninstall) UNINSTALL=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option $1 (see: sh install.sh --help)" ;;
    esac
  done
  FROM=${FROM%/}
  layout
  if [ -n "$UNINSTALL" ]; then
    TMP=$(mktemp -d 2>/dev/null || mktemp -d -t breezectl) || die "cannot make a temporary directory"
    trap 'rm -rf "$TMP"' EXIT
    trap 'exit 130' INT TERM
    uninstall
    exit 0
  fi
  command -v curl >/dev/null 2>&1 ||
    die "breezectl needs curl, and this system has none: install it (apt, dnf, apk, pacman, pkg, brew install curl), then run this again"
  TMP=$(mktemp -d 2>/dev/null || mktemp -d -t breezectl) || die "cannot make a temporary directory"
  trap 'rm -rf "$TMP"' EXIT
  trap 'exit 130' INT TERM
  [ -n "$DRY" ] && say "Dry run: nothing will be changed."
  download
  install_files
  setup_shells
  if [ -z "$DRY" ]; then
    # help, not version: version asks the saved server too.
    v=$("$BIN/breezectl" help 2>/dev/null | sed -n '1s/^\(breezectl [^ ]*\).*/\1/p')
    [ -n "$v" ] || die "$BIN/breezectl was installed but does not run"
    say "Installed $v."
  fi
  pair
}

main "$@"
