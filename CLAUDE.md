# breezectl -- notes for working on it

`breeze-core control` for client machines: `breezectl` (POSIX sh + curl) and
`breezectl.ps1` (Windows PowerShell 5.1 / PowerShell 7), with installers and
tab completion. The server is
[breeze-core-native](https://github.com/monikapurpl3/breeze-core-native); its
`crates/breeze-core/src/cli/control.rs` is the reference for every word and
message here.

## Layout

| | |
|---|---|
| `breezectl` | the sh client, one file |
| `breezectl.ps1` | the PowerShell client, one file |
| `install.sh`, `install.ps1` | the `curl \| sh` / `irm \| iex` installers |
| `completions/` | zsh (`_breezectl`), bash, fish, PowerShell |
| `stage.sh OUT` | what aspic serves under `/breezectl/`, plus `SHA256SUMS` |
| `tests/run.sh`, `tests/run.ps1` | the clients' own logic, no server: the same cases in both |
| `tests/install-unix.sh` | install.sh as zsh/bash/fish/dash users and root, in a container |
| `tests/install-windows.ps1` | install.ps1, on a throwaway registry key |
| `tests/zsh-capture.zsh` | prints what zsh's completion offers, for tests |

## Rules that are not obvious from the code

- **The two clients say the same things.** Same commands, same words, same
  sentences, same exit codes (0 done, 1 failed, 2 usage). A change to one is a
  change to both, and to both test files. A unit refusing part of a request is
  still exit 0, as on the server.
- **sh is strictly POSIX**: no `local`, arrays, `[[`, `echo -e`, `head -c`,
  `sed -i`; awk is POSIX awk (BWK awk, mawk, busybox). Run `tests/run.sh` under
  dash, `bash --posix`, busybox sh, mksh, ksh93, posh and zsh, and with mawk,
  gawk and BWK awk. Run by zsh, the script `emulate sh`s itself.
- **The .ps1 files are plain ASCII.** Windows PowerShell 5.1 reads a script
  without a BOM as the ANSI code page. Non-ASCII output is built from code
  points (`[char]0x00B0`). `stage.sh` refuses a .ps1 that is not ASCII.
- **Secrets never reach a command line.** sh hands curl its config on stdin
  (`curl -K -`); the key is read with `--key-stdin` or from `/dev/tty` with
  echo off. Saved logins are mode 600 in a 700 directory; on Windows the key
  and token are DPAPI-encrypted (`*_dpapi` fields). The files keep
  breeze-core's own `cli.json` keys.
- **PowerShell gotchas met here:** `switch` runs every matching clause (break
  each one); a function returning an array unrolls it, and 5.1 makes `[]`
  `$null` -- use `@(As-List ...)`; `@(List[object])` inside a hashtable
  literal throws "Argument types do not match" -- use `.ToArray()`;
  PowerShell 7 turns ISO date strings into `[datetime]` (`Get-IsoText`);
  `Select-Object -First` on a native command leaves a failed `$LASTEXITCODE`.
- **Never test install.ps1 against the real PATH.** `tests/install-windows.ps1`
  sets `BREEZECTL_TEST_ENV_KEY` (another key under HKCU) and
  `BREEZECTL_TEST_PROFILE`; it deletes its key afterwards. Compare the real
  `HKCU\Environment\Path` by hash before and after if in doubt.
- **The Windows PATH is edited only one way**: raw read
  (`DoNotExpandEnvironmentNames`), append if absent (normalised,
  case-insensitive), value kind kept, backup first, read back and restored if
  different, `WM_SETTINGCHANGE` broadcast. Never `setx`, never
  `[Environment]::SetEnvironmentVariable`, never HKLM.
- **Startup files** get one block between `# >>> breezectl >>>` and
  `# <<< breezectl <<<`, written with `cat >` (symlinks into dotfiles repos
  survive), with a `.breezectl-backup` copy. A reinstall must leave them
  byte-identical; an uninstall must give them back.
- **install.sh runs as `curl | sh`**: everything is in functions and `main`
  runs on the last line; nothing may read stdin (redirect `</dev/null`).
  install.ps1 runs under `irm | iex`, in the caller's session: everything is
  in a child script block, and nothing may `exit`.
- **Shell heredocs halve backslashes in this environment**: write edit
  scripts with the Write tool, never `cat <<EOF` with `\\` in them.

## Testing against something real

- Unit-free: `sh tests/run.sh`, `pwsh -File tests/run.ps1`.
- A server with emulated units: breeze-mock's `examples/bench.rs` +
  `breeze-core serve --port 18433` with `AC_CONFIG_DIR` at its store; key
  `bench-key-not-a-secret`. From containers it is `host.docker.internal:18433`.
- Real units: only brief tests on the maintainer's say-so, and every setting
  restored exactly afterwards.

## Publishing

`sh stage.sh OUT` (refuses a dirty tree) -> copied into breeze-core-native's
aspic tree under `breezectl/` by its build -> `site/publish.sh`. Publishing,
like creating the GitHub repo, waits for the maintainer's yes.
