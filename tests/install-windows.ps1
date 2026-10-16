# Tests for install.ps1 on Windows -- without touching the real PATH or profile.
#
#   pwsh -NoProfile -File tests\install-windows.ps1 -Dist DIR
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\install-windows.ps1 -Dist DIR
#
# DIR is the output of `sh stage.sh --dirty DIR`. The installer is pointed at
# a throwaway key, HKCU\Software\breezectl-test\Environment, through
# BREEZECTL_TEST_ENV_KEY, and at a scratch profile; the key is deleted at the
# end. PATH values with %VARIABLES%, an empty entry, a trailing semicolon and
# a non-ASCII folder go in, and must come out byte for byte.
#
# ASCII only, as the scripts it tests are.

param([Parameter(Mandatory = $true)][string]$Dist, [string]$PowerShell = 'powershell')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('breezectl-install-test-' + [Guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$keyPath = 'Software\breezectl-test\Environment'
$env:BREEZECTL_TEST_ENV_KEY = $keyPath
$env:BREEZECTL_TEST_PROFILE = Join-Path $work 'profile.ps1'
$env:BREEZECTL_CONFIG = Join-Path $work 'config'
$install = Join-Path $work 'Programs\breezectl'
$bin = Join-Path $install 'bin'

$script:Pass = 0; $script:Failed = 0
function Eq([string]$name, $got, $want) {
    if ([string]$got -ceq [string]$want) { $script:Pass++ }
    else { $script:Failed++; Write-Host "FAIL: $name"; Write-Host "  got:  $got"; Write-Host "  want: $want" }
}
function Ok([string]$name, [bool]$cond) { if ($cond) { $script:Pass++ } else { $script:Failed++; Write-Host "FAIL: $name" } }

function Set-TestPath($value, $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($keyPath)
    try {
        if ($null -eq $value) { $k.DeleteValue('Path', $false) } else { $k.SetValue('Path', $value, $kind) }
    } finally { $k.Close() }
}
function Get-TestPath {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($keyPath)
    try {
        if (@($k.GetValueNames()) -notcontains 'Path') { return @{ Value = $null; Kind = 'none' } }
        return @{ Value = $k.GetValue('Path', $null, 'DoNotExpandEnvironmentNames'); Kind = [string]$k.GetValueKind('Path') }
    } finally { $k.Close() }
}
function Run-Installer([string[]]$more) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'install.ps1'), '-From', $Dist, '-InstallDir', $install, '-NoLogin') + $more
    $out = & $PowerShell @a 2>&1 | Out-String
    return $out
}

try {
    # A PATH worth keeping intact: variables unexpanded, an empty entry, a
    # trailing semicolon, a folder name beyond ASCII.
    $cajna = 'C:\Tools\' + [string][char]0x010C + 'ajna'
    $original = '%USERPROFILE%\bin;C:\Tools;;' + $cajna + ';%SystemRoot%\x;'
    Set-TestPath $original
    $profileBytes = [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("# my profile -- " + [char]0x010C + "ajna`r`nSet-Alias ll Get-ChildItem`r`n")
    [IO.File]::WriteAllBytes($env:BREEZECTL_TEST_PROFILE, $profileBytes)

    # --- install
    $env:BREEZECTL_TEST_ANSWER = 'y'
    $out = Run-Installer @()
    Ok 'install reports success' ($out -match 'Installed breezectl ')
    if ($out -notmatch 'Installed breezectl ') { Write-Host $out }
    $p = Get-TestPath
    Eq 'PATH: appended, nothing else changed' $p.Value ($original + $bin)
    Eq 'PATH: kind kept' $p.Kind 'ExpandString'
    Ok 'PATH: a backup was written' (@(Get-ChildItem $install -Filter 'path-backup-*.txt').Count -eq 1)
    $backup = Get-Content -Raw (Get-ChildItem $install -Filter 'path-backup-*.txt' | Select-Object -First 1).FullName
    Ok 'PATH: the backup holds the old value' ($backup.Contains($original))
    Ok 'shim installed' (Test-Path (Join-Path $bin 'breezectl.cmd'))
    $help = & (Join-Path $bin 'breezectl.cmd') help | Select-Object -First 1
    Ok 'the shim runs breezectl' ($help -match '^breezectl \d')
    # A saved login, decrypted by Windows PowerShell started through the shim
    # from whichever PowerShell runs this test: from PowerShell 7 that used to
    # inherit 7's module path and fail to load ConvertTo-SecureString.
    $sv = Join-Path $env:BREEZECTL_CONFIG 'servers'
    New-Item -ItemType Directory -Force -Path $sv | Out-Null
    $enc = { param($t) ConvertFrom-SecureString (ConvertTo-SecureString $t -AsPlainText -Force) }
    [ordered]@{ base_url = 'http://127.0.0.1:9'; api_key_dpapi = (& $enc 'k'); device_token_dpapi = (& $enc 't'); token_id = 'x'; label = 'shim test' } |
        ConvertTo-Json | Set-Content -Encoding ASCII (Join-Path $sv 'shimtest.json')
    # Continue for this call: in 5.1, stderr through 2>&1 under Stop is a
    # terminating error, and this one is expected.
    $out = & { $ErrorActionPreference = 'Continue'; & (Join-Path $bin 'breezectl.cmd') --server shimtest status 2>&1 } | Out-String
    Ok "the shim decrypts a saved login ($($PSVersionTable.PSEdition) starting it): $($out.Trim())" ($out -match 'cannot connect to http://127\.0\.0\.1:9')
    Remove-Item (Join-Path $sv 'shimtest.json')
    $prof = [IO.File]::ReadAllBytes($env:BREEZECTL_TEST_PROFILE)
    Ok 'profile: the old bytes are untouched' ([Convert]::ToBase64String($prof[0..($profileBytes.Length - 1)]) -eq [Convert]::ToBase64String($profileBytes))
    $profText = [Text.Encoding]::UTF8.GetString($prof)
    Ok 'profile: the block was added' ($profText.Contains('# >>> breezectl >>>') -and $profText.Contains('breezectl-completion.ps1'))
    Ok 'profile: a backup was kept' (Test-Path ($env:BREEZECTL_TEST_PROFILE + '.breezectl-backup'))

    # --- again: nothing changes
    $out = Run-Installer @()
    Eq 'reinstall: PATH unchanged' (Get-TestPath).Value ($original + $bin)
    Ok 'reinstall: says so' ($out -match 'already on your PATH')
    Ok 'reinstall: profile already has it' ($out -match 'already loads the tab completion')
    Eq 'reinstall: still one backup' @(Get-ChildItem $install -Filter 'path-backup-*.txt').Count 1

    # --- the completer the profile loads
    $env:BREEZECTL_CONFIG = Join-Path $work 'config'
    New-Item -ItemType Directory -Force -Path (Join-Path $env:BREEZECTL_CONFIG 'servers'), (Join-Path $env:BREEZECTL_CONFIG 'cache') | Out-Null
    '{}' | Set-Content (Join-Path $env:BREEZECTL_CONFIG 'servers\home.json')
    [IO.File]::WriteAllText((Join-Path $env:BREEZECTL_CONFIG 'cache\home.units'), "Kitchen`nLiving room`n" + 'Dnevna ' + [char]0x010C + "ajna`n", (New-Object Text.UTF8Encoding($false)))
    $env:Path = $bin + ';' + $env:Path
    . (Join-Path $install 'breezectl-completion.ps1')
    function Complete([string]$line) { @((TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches | ForEach-Object { $_.CompletionText }) -join '|' }
    Eq 'complete: first word' (Complete 'breezectl ki') 'Kitchen'
    Eq 'complete: a name with a space is quoted' (Complete 'breezectl liv') "'Living room'"
    Eq 'complete: beyond ASCII' (Complete 'breezectl dnev') ("'Dnevna " + [char]0x010C + "ajna'")
    Eq 'complete: mode slot' (Complete 'breezectl kitchen c') 'cool'
    Eq 'complete: flap slot' (Complete 'breezectl kitchen cool 24 h') 'horizontal'
    Eq 'complete: timers' (Complete 'breezectl timers c') 'cancel'
    Eq 'complete: servers use' (Complete 'breezectl servers use h') 'home'
    Eq 'complete: a command' (Complete 'breezectl sta') 'status'

    # --- uninstall: back to exactly what it was
    $out = Run-Installer @('-Uninstall')
    $p = Get-TestPath
    Eq 'uninstall: PATH exactly as before' $p.Value $original
    Eq 'uninstall: kind kept' $p.Kind 'ExpandString'
    $prof = [IO.File]::ReadAllBytes($env:BREEZECTL_TEST_PROFILE)
    Eq 'uninstall: profile exactly as before' ([Convert]::ToBase64String($prof)) ([Convert]::ToBase64String($profileBytes))
    Ok 'uninstall: shim gone' (-not (Test-Path (Join-Path $bin 'breezectl.cmd')))
    Ok 'uninstall: script gone' (-not (Test-Path (Join-Path $install 'breezectl.ps1')))
    Ok 'uninstall: mentions the saved login' ($out -match 'Kept your saved logins')

    # --- PATH changed by someone else in between: only our entry goes
    Set-TestPath $original
    $out = Run-Installer @()
    $p = Get-TestPath
    Set-TestPath ($p.Value + ';D:\Later')
    $out = Run-Installer @('-Uninstall')
    # The trailing semicolon was the separator before our entry; it now
    # separates the later one.
    Eq 'uninstall after a change: only our entry goes' (Get-TestPath).Value ($original + 'D:\Later')

    # --- already there, spelled differently
    Set-TestPath ('C:\A;' + $bin.ToUpperInvariant() + '\;C:\B')
    $out = Run-Installer @()
    Eq 'already there in other case and with a backslash' (Get-TestPath).Value ('C:\A;' + $bin.ToUpperInvariant() + '\;C:\B')
    $out = Run-Installer @('-Uninstall')
    Eq 'uninstall takes out the differently spelled entry' (Get-TestPath).Value 'C:\A;C:\B'

    # --- no Path value at all
    Set-TestPath $null
    $out = Run-Installer @()
    $p = Get-TestPath
    Eq 'no PATH before: created with just ours' $p.Value $bin
    Eq 'no PATH before: as REG_EXPAND_SZ' $p.Kind 'ExpandString'
    $out = Run-Installer @('-Uninstall')
    Eq 'no PATH before: gone again' (Get-TestPath).Kind 'none'

    # --- REG_SZ stays REG_SZ
    Set-TestPath 'C:\A' ([Microsoft.Win32.RegistryValueKind]::String)
    $out = Run-Installer @()
    $p = Get-TestPath
    Eq 'REG_SZ: kept' $p.Kind 'String'
    Eq 'REG_SZ: appended' $p.Value ('C:\A;' + $bin)
    $out = Run-Installer @('-Uninstall')

    # --- long PATH: still appended whole, never cut
    $long = (1..300 | ForEach-Object { "C:\Some\Long\Folder\Number$_" }) -join ';'
    Set-TestPath $long
    $out = Run-Installer @()
    Eq "a $($long.Length)-character PATH is kept whole" (Get-TestPath).Value ($long + ';' + $bin)
    $out = Run-Installer @('-Uninstall')
    Eq 'and comes back whole' (Get-TestPath).Value $long

    # --- a checksum that does not match installs nothing
    $bad = Join-Path $work 'bad-dist'
    Copy-Item -Recurse $Dist $bad
    Add-Content -Path (Join-Path $bad 'breezectl.ps1') -Value '# tampered'
    Set-TestPath 'C:\A'
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'install.ps1'), '-From', $bad, '-InstallDir', (Join-Path $work 'other'), '-NoLogin')
    $out = & $PowerShell @a 2>&1 | Out-String
    Ok 'tampered: refused' ($out -match 'does not match its checksum')
    Ok 'tampered: nothing installed' (-not (Test-Path (Join-Path $work 'other')))
    Eq 'tampered: PATH untouched' (Get-TestPath).Value 'C:\A'

    # --- dry run changes nothing
    $out = Run-Installer @('-DryRun')
    Eq 'dry run: PATH untouched' (Get-TestPath).Value 'C:\A'
    Ok 'dry run: nothing installed' (-not (Test-Path (Join-Path $bin 'breezectl.cmd')))
} finally {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\breezectl-test', $false)
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ("{0} passed, {1} failed ({2})" -f $script:Pass, $script:Failed, $PowerShell)
if ($script:Failed -gt 0) { exit 1 }
exit 0
