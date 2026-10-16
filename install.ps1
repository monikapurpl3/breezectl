# install.ps1 -- install breezectl for Windows, then pair it with a server.
#
#   irm https://aspic.salataputarica.hr.eu.org/breezectl/install.ps1 | iex
#
# With options:
#   & ([scriptblock]::Create((irm https://aspic.salataputarica.hr.eu.org/breezectl/install.ps1))) -NoLogin
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#
# What it does, and nothing more:
#   * downloads breezectl.ps1 and its tab completion, and checks each against
#     SHA256SUMS before anything is installed;
#   * installs them in %LOCALAPPDATA%\Programs\breezectl, with a breezectl.cmd
#     in its bin folder that runs breezectl.ps1 -- so `breezectl` works from
#     PowerShell, cmd and Windows Terminal alike, without changing anyone's
#     execution policy (each run is -ExecutionPolicy Bypass, for that run);
#   * adds that bin folder to YOUR PATH (HKCU\Environment), carefully:
#       - the value is read raw, %VARIABLES% unexpanded, and written back with
#         its kind (REG_EXPAND_SZ) kept, through the registry API -- never
#         setx, which cuts PATH to 1024 characters, and never
#         [Environment]::SetEnvironmentVariable, which expands every %VAR%;
#       - only appended to, and only if the folder is not there already;
#       - saved first to %LOCALAPPDATA%\Programs\breezectl\path-backup-*.txt;
#       - read back after writing, and put back as it was if it differs;
#       - the system PATH (HKLM) is never touched;
#   * asks before adding tab completion to your PowerShell profile;
#   * runs `breezectl login`, the pairing wizard.
#
# -Uninstall removes all of it again, the PATH entry by the same careful path,
# and keeps your saved logins (%APPDATA%\breezectl), saying how to revoke them.
#
# Plain ASCII: Windows PowerShell 5.1 reads a file without a BOM as ANSI.
#
# Copyright 2026 Monika. AGPL-3.0-or-later; see LICENSE.

param(
    [string]$InstallDir,
    [string]$From,
    [string]$Url,
    [switch]$NoPath,
    [switch]$NoProfile,
    [switch]$NoLogin,
    [switch]$DryRun,
    [switch]$Uninstall
)

# Everything runs in a child scope: under `irm | iex` this script runs in the
# caller's own session, which must not be left holding its variables -- and
# must never be closed by an `exit`.
& {
param($InstallDir, $From, $Url, $NoPath, $NoProfile, $NoLogin, $DryRun, $Uninstall)

$ErrorActionPreference = 'Stop'
$DefaultFrom = 'https://aspic.salataputarica.hr.eu.org/breezectl'
$Files = @('breezectl.ps1', 'completions/breezectl-completion.ps1')
$BeginMark = '# >>> breezectl >>>'
$EndMark = '# <<< breezectl <<<'

function Say([string]$text) { Write-Host $text }
function Warn([string]$text) { Write-Warning $text }
function Stop-Install([string]$text) { throw (New-Object System.InvalidOperationException($text)) }

# ---------------------------------------------------------------- where

$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)
if (-not $onWindows) {
    Say 'This installer is for Windows. On Linux, macOS, the BSDs and Termux, use:'
    Say "  curl -fsSL $DefaultFrom/install.sh | sh"
    return
}
if (-not $From) { $From = $env:BREEZECTL_FROM }
if (-not $From) { $From = $DefaultFrom }
$From = $From.TrimEnd('/', '\')
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\breezectl' }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$BinDir = Join-Path $InstallDir 'bin'
$ConfigDir = $env:BREEZECTL_CONFIG
if (-not $ConfigDir) { $ConfigDir = Join-Path $env:APPDATA 'breezectl' }
# For tests only: another key under HKCU to treat as the user's environment,
# so a test never touches the real PATH.
$EnvKeyPath = 'Environment'
if ($env:BREEZECTL_TEST_ENV_KEY) { $EnvKeyPath = $env:BREEZECTL_TEST_ENV_KEY }
$StateFile = Join-Path $InstallDir 'path-state.json'
$ProfilePath = $PROFILE.CurrentUserAllHosts
if ($env:BREEZECTL_TEST_PROFILE) { $ProfilePath = $env:BREEZECTL_TEST_PROFILE }

# ------------------------------------------------------------- fetching

Add-Type -AssemblyName System.Net.Http
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function Get-Bytes([string]$relative) {
    if ($From -match '^https?://') {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        $response = $null; $failure = $null; $bytes = $null
        try {
            $response = $client.GetAsync("$From/$relative").GetAwaiter().GetResult()
            if ($response.IsSuccessStatusCode) { $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult() }
        } catch { $failure = $_.Exception.GetBaseException().Message }
        finally { $client.Dispose() }
        if ($failure) { Stop-Install "cannot fetch $From/${relative}: $failure" }
        if (-not $response.IsSuccessStatusCode) { Stop-Install "cannot fetch $From/$relative (HTTP $([int]$response.StatusCode))" }
        if ($From -like 'https://*' -and $response.RequestMessage.RequestUri.Scheme -ne 'https') { Stop-Install "$From/$relative was redirected away from HTTPS" }
        return , $bytes
    }
    $path = Join-Path $From ($relative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path)) { Stop-Install "$path does not exist" }
    return , [IO.File]::ReadAllBytes($path)
}

function Get-Sha256([byte[]]$bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })) }
    finally { $sha.Dispose() }
}

function Get-Download {
    if ($From -like 'http://*') { Warn 'fetching over plain HTTP: the checksums can only catch a broken download, not a tampered one' }
    Say "Fetching breezectl from $From ..."
    $sums = [Text.Encoding]::ASCII.GetString((Get-Bytes 'SHA256SUMS'))
    $want = @{}
    foreach ($line in ($sums -split "`r?`n")) {
        if ($line -match '^([0-9a-f]{64}) [ *]?(\S+)$') { $want[$Matches[2]] = $Matches[1] }
    }
    $got = @{}
    foreach ($f in $Files) {
        if (-not $want.ContainsKey($f)) { Stop-Install "SHA256SUMS does not list $f" }
        $bytes = Get-Bytes $f
        $hash = Get-Sha256 $bytes
        if ($hash -ne $want[$f]) { Stop-Install "$f does not match its checksum -- nothing installed (expected $($want[$f]), got $hash)" }
        $got[$f] = $bytes
    }
    Say "All $($Files.Count) files match their checksums."
    return $got
}

# ----------------------------------------------------------- installing

function Write-FileBytes([string]$path, [byte[]]$bytes) {
    if ($DryRun) { Say "  would install $path"; return }
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllBytes($path + '.partial', $bytes)
    Move-Item -LiteralPath ($path + '.partial') -Destination $path -Force
    Say "  installed $path"
}

# cmd's own quoting, not PowerShell's: it passes its arguments on untouched.
# Always Windows PowerShell 5.1 -- the one every Windows has, at a path that
# never moves.
#
# Without PSModulePath: run from PowerShell 7, the shim would hand Windows
# PowerShell 7's module path, and it would then try to load 7's modules in
# place of its own and fail -- ConvertTo-SecureString, and with it every saved
# login. pwsh cleans that variable only when it starts powershell.exe itself,
# not through a .cmd. Unset, Windows PowerShell builds its own. setlocal keeps
# the change to this one run.
$Shim = @"
@echo off
rem breezectl: runs breezectl.ps1. Installed by the breezectl installer.
setlocal
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0..\breezectl.ps1" %*
exit /b %ERRORLEVEL%
"@

function Install-Files($downloaded) {
    Say 'Installing:'
    Write-FileBytes (Join-Path $InstallDir 'breezectl.ps1') $downloaded['breezectl.ps1']
    Write-FileBytes (Join-Path $InstallDir 'breezectl-completion.ps1') $downloaded['completions/breezectl-completion.ps1']
    Write-FileBytes (Join-Path $BinDir 'breezectl.cmd') ([Text.Encoding]::ASCII.GetBytes(($Shim -replace "`r?`n", "`r`n") + "`r`n"))
}

# ----------------------------------------------------------------- PATH

function Get-PathKey([bool]$writable) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($EnvKeyPath, $writable)
    if ($null -eq $key -and $writable) { $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($EnvKeyPath) }
    return $key
}

function Read-RawPath($key) {
    $names = @($key.GetValueNames())
    $name = $names | Where-Object { $_ -ieq 'Path' } | Select-Object -First 1
    if (-not $name) { return @{ Name = 'Path'; Value = $null; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString } }
    return @{
        Name = $name
        Value = [string]$key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        Kind = $key.GetValueKind($name)
    }
}

function Get-NormalPath([string]$entry) {
    $e = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\', '/')
    try { $e = [IO.Path]::GetFullPath($e).TrimEnd('\') } catch { }
    return $e
}

function Test-PathHas([string]$raw, [string]$dir) {
    if (-not $raw) { return $false }
    $want = Get-NormalPath $dir
    foreach ($entry in ($raw -split ';')) {
        if ($entry.Trim() -and [string]::Equals((Get-NormalPath $entry), $want, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Tells running programs -- Explorer above all, which starts the next
# terminal -- that the environment changed, as the System dialog does.
function Send-EnvironmentChange {
    if ($env:BREEZECTL_TEST_ENV_KEY) { return }
    try {
        if (-not ('BreezectlInstall.Native' -as [type])) {
            Add-Type -Namespace BreezectlInstall -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $result = [UIntPtr]::Zero
        [BreezectlInstall.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
    } catch { Warn 'could not tell Windows the environment changed; a new sign-in will pick it up' }
}

function Save-PathBackup($raw) {
    $file = Join-Path $InstallDir ('path-backup-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt')
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $text = "Your PATH (HKCU\$EnvKeyPath), as it was before the breezectl installer changed it.`r`n"
    $text += "Kind: $($raw.Kind)`r`n"
    if ($null -eq $raw.Value) { $text += "(there was no Path value)`r`n" } else { $text += "Value:`r`n$($raw.Value)`r`n" }
    [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($true)))
    return $file
}

# Writes the new value, reads it back, and puts the old one back if the two
# differ. Returns whether it held.
function Set-RawPath($key, $raw, $new) {
    if ($null -eq $new) {
        # There was no Path value before the install: there is none after.
        $key.DeleteValue($raw.Name, $false)
        if ($null -eq (Read-RawPath $key).Value) { return $true }
    } else {
        $key.SetValue($raw.Name, [string]$new, $raw.Kind)
        $check = Read-RawPath $key
        if ($check.Value -ceq $new -and $check.Kind -eq $raw.Kind) { return $true }
    }
    if ($null -eq $raw.Value) { $key.DeleteValue($raw.Name, $false) } else { $key.SetValue($raw.Name, $raw.Value, $raw.Kind) }
    return $false
}

function Add-ToUserPath([string]$dir) {
    $key = Get-PathKey $true
    try {
        $raw = Read-RawPath $key
        if ($raw.Kind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString -and $raw.Kind -ne [Microsoft.Win32.RegistryValueKind]::String) {
            Warn "your PATH is stored as $($raw.Kind), which this installer does not edit; add $dir to it yourself"
            return
        }
        if (Test-PathHas $raw.Value $dir) { Say "  $dir is already on your PATH."; return }
        $machine = [string][Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment').GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if (Test-PathHas $machine $dir) { Say "  $dir is already on the system PATH."; return }
        if (-not $raw.Value) { $new = $dir }
        elseif ($raw.Value.EndsWith(';')) { $new = $raw.Value + $dir }
        else { $new = $raw.Value + ';' + $dir }
        # Windows takes no single environment value over 32767 characters.
        if ($new.Length -gt 32000) { Warn "your PATH is $($raw.Value.Length) characters long, too long to add to safely; add $dir yourself"; return }
        if ($DryRun) { Say "  would add $dir to the end of your PATH (HKCU\$EnvKeyPath)"; return }
        $backup = Save-PathBackup $raw
        if (-not (Set-RawPath $key $raw $new)) { Warn "your PATH did not read back as written, so it was put back as it was; add $dir yourself"; return }
        Say "  added $dir to the end of your PATH (the value as it was: $backup)"
        # So that -Uninstall can put it back exactly, if nothing else changed it since.
        $state = [ordered]@{ key = $EnvKeyPath; existed = ($null -ne $raw.Value); before = [string]$raw.Value; after = $new }
        [IO.File]::WriteAllText($StateFile, ($state | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    } finally { $key.Close() }
    Send-EnvironmentChange
    if (-not (Test-PathHas $env:Path $dir)) { $env:Path = $env:Path.TrimEnd(';') + ';' + $dir }
}

function Remove-FromUserPath([string]$dir) {
    $key = Get-PathKey $true
    try {
        $raw = Read-RawPath $key
        if (-not (Test-PathHas $raw.Value $dir)) { return }
        $state = $null
        if (Test-Path -LiteralPath $StateFile) { try { $state = [IO.File]::ReadAllText($StateFile) | ConvertFrom-Json } catch { } }
        if ($state -and $state.key -eq $EnvKeyPath -and [string]$state.after -ceq $raw.Value) {
            # Untouched since the install: back to exactly what it was.
            $new = $null
            if ($state.existed) { $new = [string]$state.before }
        } else {
            # Changed since: take out only the entry, leaving every other one,
            # empty ones included, as it is.
            $want = Get-NormalPath $dir
            $kept = @($raw.Value -split ';' | Where-Object { -not ($_.Trim() -and [string]::Equals((Get-NormalPath $_), $want, [StringComparison]::OrdinalIgnoreCase)) })
            $new = $kept -join ';'
        }
        if ($DryRun) { Say "  would take $dir out of your PATH"; return }
        $backup = Save-PathBackup $raw
        if (-not (Set-RawPath $key $raw $new)) { Warn "your PATH did not read back as written, so it was put back as it was; take $dir out yourself"; return }
        Say "  took $dir out of your PATH (the value as it was: $backup)"
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    } finally { $key.Close() }
    Send-EnvironmentChange
}

# -------------------------------------------------------------- profile
#
# The profile is read and written as Latin-1, byte for byte, unless it starts
# with a UTF-16 mark: whatever its encoding, every byte outside the block comes
# back exactly as it was. The block itself is ASCII.

function Get-ProfileEncoding([byte[]]$bytes) {
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode }
    return [Text.Encoding]::GetEncoding(28591)
}

function Remove-Block([string]$text) {
    $nl = "`r`n"; if ($text -notmatch "`r`n" -and $text -match "`n") { $nl = "`n" }
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in ($text -split "`r?`n")) {
        if ($skip) { if ($line -ceq $EndMark) { $skip = $false }; continue }
        if ($line -ceq $BeginMark) {
            $skip = $true
            if ($out.Count -gt 0 -and $out[$out.Count - 1] -eq '') { $out.RemoveAt($out.Count - 1) }
            continue
        }
        $out.Add($line)
    }
    return @{ Text = ($out -join $nl); NewLine = $nl }
}

function Write-ProfileText([string]$path, [string]$text, $encoding, [bool]$hadBom) {
    $bytes = $encoding.GetBytes($text)
    if ($hadBom) { $bytes = $encoding.GetPreamble() + $bytes }
    [IO.File]::WriteAllBytes($path, $bytes)
}

function Add-ProfileCompletion {
    if ($NoProfile) { return }
    $policy = Get-ExecutionPolicy
    if (@('Restricted', 'AllSigned', 'Undefined') -contains [string]$policy) {
        Say "  Tab completion not offered: this PowerShell's execution policy ($policy) would not run a profile."
        return
    }
    $block = @(
        $BeginMark,
        '# Added by the breezectl installer: tab completion for breezectl. Remove this',
        '# block, or run the installer with -Uninstall, to undo.',
        ('if (Test-Path -LiteralPath ''{0}'') {{ . ''{0}'' }}' -f (Join-Path $InstallDir 'breezectl-completion.ps1').Replace("'", "''")),
        $EndMark
    )
    $exists = Test-Path -LiteralPath $ProfilePath
    if ($exists) {
        $bytes = [IO.File]::ReadAllBytes($ProfilePath)
        $encoding = Get-ProfileEncoding $bytes
        $bomLength = $encoding.GetPreamble().Length
        if ($encoding.CodePage -eq 28591) { $bomLength = 0 }
        $text = $encoding.GetString($bytes, $bomLength, $bytes.Length - $bomLength)
        if ($text.Contains($BeginMark)) { Say "  $ProfilePath already loads the tab completion."; return }
    }
    if (-not $DryRun -and $env:BREEZECTL_TEST_PROFILE -and $env:BREEZECTL_TEST_ANSWER) {
        if ($env:BREEZECTL_TEST_ANSWER -notmatch '^[yY]') { Say '  Left your profile alone.'; return }
    } elseif (-not $DryRun -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        $answer = Read-Host "Add tab completion for breezectl to your PowerShell profile ($ProfilePath)? [y/N]"
        if ($answer -notmatch '^[yY]') { Say '  Left your profile alone.'; return }
    } elseif (-not $DryRun) {
        Say "  Tab completion: run the installer in a terminal to be asked, or dot-source $(Join-Path $InstallDir 'breezectl-completion.ps1') from your profile."
        return
    }
    if ($DryRun) { Say "  would offer to add tab completion to $ProfilePath"; return }
    if ($exists) {
        $kept = Remove-Block $text
        $nl = $kept.NewLine
        $newText = $kept.Text.TrimEnd("`r", "`n") + $nl + $nl + ($block -join $nl) + $nl
        if (-not $kept.Text.Trim()) { $newText = ($block -join $nl) + $nl }
        Copy-Item -LiteralPath $ProfilePath -Destination ($ProfilePath + '.breezectl-backup') -Force
        Write-ProfileText $ProfilePath $newText $encoding ($bomLength -gt 0)
        Say "  added tab completion to $ProfilePath (the file as it was: $ProfilePath.breezectl-backup)"
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $ProfilePath) | Out-Null
        [IO.File]::WriteAllText($ProfilePath, ($block -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
        Say "  created $ProfilePath, with tab completion for breezectl"
    }
    Say '  It works in new PowerShell windows.'
}

function Remove-ProfileCompletion {
    if (-not (Test-Path -LiteralPath $ProfilePath)) { return }
    $bytes = [IO.File]::ReadAllBytes($ProfilePath)
    $encoding = Get-ProfileEncoding $bytes
    $bomLength = $encoding.GetPreamble().Length
    if ($encoding.CodePage -eq 28591) { $bomLength = 0 }
    $text = $encoding.GetString($bytes, $bomLength, $bytes.Length - $bomLength)
    if (-not $text.Contains($BeginMark)) { return }
    if ($DryRun) { Say "  would take the breezectl block out of $ProfilePath"; return }
    $kept = Remove-Block $text
    Copy-Item -LiteralPath $ProfilePath -Destination ($ProfilePath + '.breezectl-backup') -Force
    Write-ProfileText $ProfilePath $kept.Text $encoding ($bomLength -gt 0)
    Say "  took the breezectl block out of $ProfilePath (the file as it was: $ProfilePath.breezectl-backup)"
}

# ------------------------------------------------------------ uninstall

function Invoke-Uninstall {
    Say 'Removing breezectl:'
    if (-not $NoPath) { Remove-FromUserPath $BinDir }
    Remove-ProfileCompletion
    foreach ($f in @((Join-Path $BinDir 'breezectl.cmd'), (Join-Path $InstallDir 'breezectl.ps1'), (Join-Path $InstallDir 'breezectl-completion.ps1'))) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        if ($DryRun) { Say "  would remove $f" } else { Remove-Item -LiteralPath $f -Force; Say "  removed $f" }
    }
    if (-not $DryRun) {
        foreach ($d in @($BinDir, $InstallDir)) {
            if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d -Force }
        }
        if (Test-Path -LiteralPath $InstallDir) { Say "  kept $InstallDir for the PATH backups in it" }
    }
    $servers = Join-Path $ConfigDir 'servers'
    if ((Test-Path -LiteralPath $servers) -and (Get-ChildItem -LiteralPath $servers -Filter '*.json')) {
        Say ''
        Say "Kept your saved logins in $ConfigDir. Each is a device token that stays"
        Say "valid on its server until it is revoked: revoke it in the server's web panel,"
        Say 'or reinstall and run breezectl logout NAME. Then delete that folder.'
    }
}

# ------------------------------------------------------------------ main

function Invoke-Install {
    if ($DryRun) { Say 'Dry run: nothing will be changed.' }
    $policies = @('MachinePolicy', 'UserPolicy') | ForEach-Object { [string](Get-ExecutionPolicy -Scope $_) } | Where-Object { $_ -ne 'Undefined' }
    if ($policies | Where-Object { @('Restricted', 'AllSigned') -contains $_ }) {
        Warn "Group Policy sets PowerShell's execution policy to $($policies -join '/') here, which overrides -ExecutionPolicy Bypass: breezectl.ps1 will not run unless it is signed."
    }
    $downloaded = Get-Download
    Install-Files $downloaded
    Say 'PATH:'
    if ($NoPath) {
        Say "  Left your PATH alone. Run breezectl as $(Join-Path $BinDir 'breezectl.cmd'), or add $BinDir to PATH yourself."
    } else {
        Add-ToUserPath $BinDir
    }
    Say 'Tab completion:'
    Add-ProfileCompletion
    if ($DryRun) { return }
    $cmd = Join-Path $BinDir 'breezectl.cmd'
    # All of it, not Select-Object -First 1, which would stop it early and
    # leave a failed exit code behind.
    $helpText = @(& $cmd help)
    $version = ([string]$helpText[0]) -replace '^(breezectl \S+).*$', '$1'
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^breezectl ') { Stop-Install "$cmd was installed but does not run" }
    Say "Installed $version. New terminals find it as breezectl; this one does already."
    if ($NoLogin) { return }
    $saved = @(& $cmd __complete servers | Where-Object { $_ })
    if ($saved.Count -gt 0 -and -not $Url) {
        Say "Already paired with: $($saved -join ' ')"
        Say 'To pair with another server: breezectl login'
        return
    }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Say 'No terminal to ask questions in. Pair this machine when ready: breezectl login'
        return
    }
    Say ''
    if ($Url) { & $cmd login $Url } else { & $cmd login }
    if ($LASTEXITCODE -ne 0) { Say 'Not paired yet. Run breezectl login when ready.' }
}

try {
    if ($Uninstall) { Invoke-Uninstall } else { Invoke-Install }
} catch {
    # Reported, not rethrown: under irm | iex an error here would be the
    # caller's own session's.
    Write-Host "breezectl install: $($_.Exception.Message)" -ForegroundColor Red
}
} $InstallDir $From $Url $NoPath $NoProfile $NoLogin $DryRun $Uninstall
