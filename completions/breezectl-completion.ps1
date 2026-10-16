# breezectl-completion.ps1 -- tab completion for breezectl in PowerShell.
#
# Dot-sourced from your PowerShell profile, if you said yes when install.ps1
# asked. Unit names come from the list breezectl keeps of the last units it
# saw, read here directly, so a Tab neither waits on the network nor starts a
# second PowerShell. Names match case-insensitively, as breezectl matches them.
#
# Plain ASCII, as breezectl.ps1 is.

Register-ArgumentCompleter -Native -CommandName 'breezectl', 'breezectl.cmd' -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)

    $configDir = $env:BREEZECTL_CONFIG
    if (-not $configDir) {
        if ($env:APPDATA -and (($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows)) { $configDir = Join-Path $env:APPDATA 'breezectl' }
        else {
            $base = $env:XDG_CONFIG_HOME
            if (-not $base) { $base = Join-Path $HOME '.config' }
            $configDir = Join-Path $base 'breezectl'
        }
    }
    $serversDir = Join-Path $configDir 'servers'

    # The words before the one being completed, unquoted.
    $words = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($commandAst.CommandElements | Select-Object -Skip 1)) {
        if ($e.Extent.EndOffset -ge $cursorPosition) { break }
        if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $words.Add($e.Value) }
        else { $words.Add($e.Extent.Text) }
    }
    $prefix = $wordToComplete -replace "^['""]", ''

    function Get-Servers {
        if (Test-Path -LiteralPath $serversDir) {
            Get-ChildItem -LiteralPath $serversDir -Filter '*.json' -File | Sort-Object Name | ForEach-Object { $_.BaseName }
        }
    }
    function Get-Units([string]$server) {
        if (-not $server) { $server = $env:BREEZECTL_SERVER }
        if (-not $server) {
            $cur = Join-Path $configDir 'current'
            if (Test-Path -LiteralPath $cur) { $server = (Get-Content -LiteralPath $cur -TotalCount 1) }
        }
        if (-not $server) {
            $all = @(Get-Servers)
            if ($all.Count -eq 1) { $server = $all[0] }
        }
        if (-not $server -or $server -notmatch '^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$') { return }
        $file = Join-Path (Join-Path $configDir 'cache') ($server + '.units')
        if (-not (Test-Path -LiteralPath $file)) {
            # Not seen yet: ask breezectl once; it saves the list for next time.
            & breezectl --server $server __complete units 2>$null | Out-Null
        }
        if (Test-Path -LiteralPath $file) {
            [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8) | Where-Object { $_ }
        }
    }
    function Offer([string[]]$candidates, [string]$kind = 'ParameterValue') {
        foreach ($c in $candidates) {
            if (-not $c -or -not $c.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $text = $c
            if ($c -match "[\s'""`$&|;,(){}@#<>]") { $text = "'" + $c.Replace("'", "''") + "'" }
            [System.Management.Automation.CompletionResult]::new($text, $c, $kind, $c)
        }
    }

    # Past the options that come before the command.
    $server = $null
    $i = 0
    while ($i -lt $words.Count) {
        if (@('--server', '-s') -contains $words[$i]) {
            if ($i + 1 -lt $words.Count) { $server = $words[$i + 1] }
            $i += 2
        } elseif ($words[$i] -like '--server=*') { $server = $words[$i].Substring(9); $i++ }
        elseif ($words[$i] -eq '--') { $i++ }
        else { break }
    }
    if ($words.Count -gt 0 -and @('--server', '-s') -contains $words[$words.Count - 1]) { Offer @(Get-Servers); return }

    $commands = @('status', 'units', 'timers', 'login', 'logout', 'servers', 'diag', 'nerd', 'version', 'help', 'control')
    $slots = @(
        @('cool', 'heat', 'dry', 'auto', 'fan', 'on', 'off', 'none'),
        @('none', '18', '19', '20', '21', '22', '23', '24', '25', '26'),
        @('both', 'horizontal', 'vertical', 'off', 'none'),
        @('silent', 'low', 'medium', 'high', 'max', 'auto', 'none'),
        @('turbo', 'eco', 'turbo+eco', 'no-turbo', 'no-eco', 'none'),
        @('15m', '30m', '45m', '1h', '2h')
    )
    if ($i -ge $words.Count) {
        if ($prefix.StartsWith('-')) { Offer @('--server', '--help', '--version'); return }
        Offer $commands 'Command'
        Offer @(Get-Units $server)
        return
    }
    $cmd = $words[$i]
    $pos = $words.Count - $i
    $sub = $null
    if ($i + 1 -lt $words.Count) { $sub = $words[$i + 1] }
    switch -CaseSensitive ($cmd) {
        { @('status', 'st') -ccontains $_ } { Offer @(Get-Units $server); return }
        { @('units', 'list', 'diag', 'doctor', 'version', 'help', 'nerd', '--help', '-h', '--version', '-V') -ccontains $_ } { return }
        { @('timers', 'timer') -ccontains $_ } {
            if ($pos -eq 1) { Offer @('list', 'off', 'start', 'cancel'); return }
            if ($sub -ceq 'off') {
                if ($pos -eq 2) { Offer @(Get-Units $server) } elseif ($pos -eq 3) { Offer @('15m', '30m', '45m', '1h', '2h') }
            } elseif (@('start', 'on') -ccontains $sub) {
                if ($pos -eq 2) { Offer @(Get-Units $server) } elseif ($pos -eq 4) { Offer @('today', 'tomorrow', '2', '3', '4', '5', '6', '7') }
            } elseif (@('cancel', 'rm', 'delete') -ccontains $sub -and $pos -eq 2) {
                Offer @('all'); Offer @(Get-Units $server)
            }
            return
        }
        { @('servers', 'server') -ccontains $_ } {
            if ($pos -eq 1) { Offer @('list', 'use', 'rename', 'remove') }
            elseif ($pos -eq 2 -and @('use', 'rename', 'remove', 'rm', 'forget') -ccontains $sub) { Offer @(Get-Servers) }
            return
        }
        { @('logout', 'unpair') -ccontains $_ } { if ($pos -eq 1) { Offer @(Get-Servers) }; return }
        { @('login', 'pair') -ccontains $_ } {
            if (@('--name', '--label', '--ca') -notcontains $words[$words.Count - 1]) { Offer @('--name', '--label', '--ca', '--key-stdin', '--yes') 'ParameterName' }
            return
        }
        'control' {
            if ($pos -eq 1) { Offer @(Get-Units $server) }
            elseif ($pos -le 7) { Offer $slots[$pos - 2] }
            return
        }
        default {
            # The first word was a unit's name.
            if ($pos -le 6) { Offer $slots[$pos - 1] }
        }
    }
}
