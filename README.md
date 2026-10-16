<div align="center">

# breezectl

**Your air conditioners, from any terminal.**

`breeze-core control`, for every machine that isn't the server — a POSIX `sh`
script and a PowerShell script that talk to [Breeze Core](https://github.com/monikapurpl3/breeze-core-native)
over its API, with saved, revocable logins.

[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)
[![Runs on](https://img.shields.io/badge/runs%20on-Linux%20·%20macOS%20·%20BSD%20·%20Termux%20·%20Windows-e69138)](#runs-on)
[![Shells](https://img.shields.io/badge/shells-sh%20·%20bash%20·%20zsh%20·%20fish%20·%20PowerShell-6aa84f)](#tab-completion)

</div>

```console
$ breezectl status
Kitchen: off, set to heat, 21.5 °C, fan auto; indoor 21.0 °C
Living room: cool, 24.0 °C, swing vertical, fan medium, indoor 23.5 °C

$ breezectl 'living room' cool 23 both auto turbo 30m
Living room: cool, 23.0 °C, swing both, fan auto, turbo, indoor 23.5 °C
Living room: switching off in 30 minutes, at 21:45
```

## Why

`breeze-core control` is the quickest way to set an air conditioner — but it
runs on the server, so using it means an SSH session or a keyboard on that
box. breezectl is the same command for your laptop, your desktop and your
phone's terminal:

- **The same words, the same messages.** A script written for
  `breeze-core control` runs unchanged with `breezectl`, and says the same
  things when a unit refuses something — the panel's, the app's and the
  server's own wording.
- **Paired, not shared.** `breezectl login` pairs this machine the way the
  Android app pairs a phone: the server's API key, a code approved on its own
  network, and then a device token of its own — listed on the server, and
  revocable there without touching anything else.
- **Saved carefully.** Readable by you alone; on Windows, encrypted for your
  account. Keys and tokens never appear on a command line, where other users
  could see them.
- **Nothing to install but itself.** The sh script needs `curl` and nothing
  else — no jq, no Python. The PowerShell one needs PowerShell.
- **More than control:** status, units, sleep and start timers, several saved
  servers, and the server's own `diag` checks from this machine's side of the
  network.

## Install

**Linux, macOS, the BSDs, Termux:**

```sh
curl -fsSL https://aspic.salataputarica.hr.eu.org/breezectl/install.sh | sh
```

**Windows** (PowerShell):

```powershell
irm https://aspic.salataputarica.hr.eu.org/breezectl/install.ps1 | iex
```

Either one checks every file against its SHA-256 before installing it, puts
`breezectl` on your PATH, sets up tab completion, and starts the pairing
wizard: the server's address, its API key, and the approval.

It changes nothing it doesn't tell you about. On Unix it adds one marked
block to your shell's startup file, and keeps a copy of the file as it was.
On Windows it appends one folder to *your* PATH — never the system's — read
and written raw, so `%VARIABLES%` stay unexpanded and nothing is cut short,
with the old value saved first. Either installer's `--uninstall`
(`-Uninstall`) takes it all out again.

<details>
<summary>Options, and installing by hand</summary>

```sh
curl -fsSL .../install.sh | sh -s -- --no-login       # pair later
curl -fsSL .../install.sh | sh -s -- --url 192.168.1.10
curl -fsSL .../install.sh | sh -s -- --dry-run        # say what it would do
sh install.sh --uninstall
```

```powershell
& ([scriptblock]::Create((irm .../install.ps1))) -NoLogin
& ([scriptblock]::Create((irm .../install.ps1))) -Uninstall
```

By hand: `breezectl` is one file. Put it anywhere on your PATH and make it
executable; check it against
[SHA256SUMS](https://aspic.salataputarica.hr.eu.org/breezectl/SHA256SUMS)
first.

</details>

## Use

```sh
breezectl login                         # pair this machine with a server
breezectl status                        # every unit
breezectl kitchen                       # one unit
breezectl kitchen heat 22.5             # mode and temperature
breezectl kitchen off
breezectl kitchen none none none none none 45m   # just a sleep timer
breezectl timers                        # what is pending
breezectl timers start bedroom 06:45 tomorrow
breezectl timers cancel all
breezectl diag                          # is anything wrong?
```

A unit is named case-insensitively, by a unique prefix, or by its id. After
the name come up to six settings, in this order, any of them `none`:

| | |
|---|---|
| **Mode** | `cool` `heat` `dry` `auto` `fan` · `on` `off` |
| **Temperature** | 16–30, in half degrees |
| **Flaps** | `both` `horizontal` `vertical` `off` |
| **Fan** | `silent` `low` `medium` `high` `max` `auto` |
| **Extra** | `turbo` `eco` `turbo+eco` `no-turbo` `no-eco` |
| **Timer** | `15m` `90min` `2h` — switches the unit off after that long |

`breezectl help` has the rest: several servers (`breezectl servers`,
`--server NAME`), `logout`, and `nerd`, which writes `diag`'s findings as a
JSON report for a bug report.

## Tab completion

zsh, bash, fish and PowerShell complete the commands, the settings in each
position, saved servers — and your units' names, from the last list breezectl
saw, so a Tab never waits on the network.

## Runs on

The sh script is strictly POSIX — no `local`, no arrays, plain POSIX awk — and
is tested under dash, bash, `bash --posix`, busybox ash, mksh, ksh93, posh,
zsh, and three awks (mawk, gawk, BWK awk): what Debian, Alpine, the BSDs,
macOS and Termux ship. The PowerShell script runs in Windows PowerShell 5.1
and PowerShell 7, on Windows, Linux and macOS.

## Honest limits

- It is a client: it needs a [Breeze Core](https://github.com/monikapurpl3/breeze-core-native)
  server, and talks to air conditioners only through one.
- A pairing has to be approved from the server's own network — in its web
  panel, or with `breeze-core approve` — unless this machine is on that network
  already. That is the point of it, not an oversight; revoking at `logout`
  is LAN-only for the same reason, and breezectl says how to do it otherwise.
- Times — `fires at 07:30`, `timers start ... 06:45` — are the server's clock,
  not this machine's.
- On Windows each command starts Windows PowerShell, which takes a moment: a
  `status` takes about 0.7 s, where the sh script takes 0.1 s.

## Security

breezectl holds a device token for each server it is paired with. Report a
vulnerability as Breeze Core's [SECURITY.md](https://github.com/monikapurpl3/breeze-core-native/blob/main/SECURITY.md)
describes, not in a public issue.

## Licence

[AGPL-3.0-or-later](LICENSE), as Breeze Core is.
