#!/bin/sh
# stage.sh OUTDIR -- the files that aspic serves under /breezectl/, with the
# SHA256SUMS the installers check them against.
#
#   sh stage.sh /tmp/breezectl-dist
#
# Refuses a working tree that differs from HEAD (--dirty to allow it, for
# tests), so what is published is always a commit.

set -eu
dirty=""
if [ "${1:-}" = --dirty ]; then dirty=1; shift; fi
out=${1:?usage: sh stage.sh [--dirty] OUTDIR}
here=$(cd "$(dirname "$0")" && pwd)

FILES="breezectl breezectl.ps1 install.sh install.ps1 LICENSE
completions/_breezectl completions/breezectl.bash completions/breezectl.fish completions/breezectl-completion.ps1"

if [ -z "$dirty" ]; then
  # shellcheck disable=SC2086
  if ! git -C "$here" diff --quiet HEAD -- $FILES || [ -n "$(git -C "$here" status --porcelain -- $FILES)" ]; then
    echo "stage.sh: the working tree differs from HEAD; commit first (or --dirty)" >&2
    exit 1
  fi
fi

# From standard input, never a file name: GNU sha256sum escapes its whole line
# with a leading backslash when the name holds one (D:\a\_temp/... on a
# Windows runner), and the hash would then start with it.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum <"$1" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 <"$1" | cut -d ' ' -f 1
  else openssl dgst -sha256 <"$1" | sed 's/^.*= *//'
  fi
}

mkdir -p "$out/completions"
: >"$out/SHA256SUMS.partial"
for f in $FILES; do
  cp "$here/$f" "$out/$f"
  case "$f" in
    *.ps1)
      # Windows PowerShell 5.1 reads a script without a BOM as the ANSI code
      # page: these must stay plain ASCII.
      if LC_ALL=C tr -d '\r\n\t -~' <"$out/$f" | LC_ALL=C grep -q .; then
        echo "stage.sh: $f is not plain ASCII" >&2
        exit 1
      fi ;;
    breezectl | install.sh | completions/*.bash | completions/_*)
      if grep -q "$(printf '\r')" "$out/$f"; then echo "stage.sh: $f has CRLF line ends" >&2; exit 1; fi ;;
  esac
  printf '%s  %s\n' "$(sha256_of "$out/$f")" "$f" >>"$out/SHA256SUMS.partial"
done
chmod 755 "$out/breezectl" "$out/install.sh"
chmod 644 "$out/breezectl.ps1" "$out/install.ps1" "$out/LICENSE" "$out/completions/"*
mv -f "$out/SHA256SUMS.partial" "$out/SHA256SUMS"
echo "staged $(printf '%s\n' $FILES | wc -l | tr -d ' ') files and SHA256SUMS in $out"
