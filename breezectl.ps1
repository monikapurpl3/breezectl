# breezectl.ps1 -- control Breeze Core from PowerShell.
#
#   breezectl 'kitchen' cool 24.5 both auto turbo 30m
#   breezectl status
#   breezectl login
#
# The server's own `breeze-core control`, for Windows and for PowerShell
# anywhere: the same words, the same messages and the same saved logins as the
# POSIX `breezectl` script beside it. Windows PowerShell 5.1 and PowerShell 7
# on Windows, Linux and macOS.
#
# Two things about this file that are deliberate:
#   * it is plain ASCII. Windows PowerShell 5.1 reads a script without a BOM as
#     the ANSI code page, so a literal degree sign would arrive as mojibake; the
#     few non-ASCII characters printed are built from their code points.
#   * HTTP goes through .NET's HttpClient rather than Invoke-WebRequest, whose
#     error handling, encoding and parsing differ between 5.1 and 7. The body
#     is always decoded as UTF-8, as JSON is.
#
# Copyright 2026 Monika. AGPL-3.0-or-later; see LICENSE.

$script:Version = '1.0.0'
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ basics

$script:OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)
$script:Deg = [string][char]0x00B0 + 'C'

class BreezeError : System.Exception {
    [int]$Code
    BreezeError([string]$message, [int]$code) : base($message) { $this.Code = $code }
}
function Fail([string]$message, [int]$code = 1) { throw [BreezeError]::new($message, $code) }
function UsageFail([string]$message) { Fail ($message + "`nbreezectl: see: breezectl help") 2 }
function Say([string]$text) { [Console]::Out.WriteLine($text) }

function Get-Field($object, [string]$name) {
    if ($null -eq $object) { return $null }
    if ($object -is [System.Collections.IDictionary]) { return $object[$name] }
    $p = $object.PSObject.Properties[$name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

# The items of a JSON array, for @(As-List ...): ConvertFrom-Json and every
# function return unroll a one-element array, and 5.1 turns an empty one into
# $null -- which @() alone would make a list of one $null.
function As-List($value) {
    if ($null -eq $value) { return }
    $value
}

# --------------------------------------------------------- saved servers
#
# One JSON file per server, with the same keys as `breeze-core`'s own cli.json
# (base_url, api_key, device_token, token_id) and a label -- the same files the
# POSIX script writes, so on Linux and macOS the two share their logins. On
# Windows the key and token are encrypted with DPAPI for this Windows account
# ("api_key_dpapi", "device_token_dpapi"): copied to another account or
# machine, the file is useless.

function Get-ConfigDir {
    if ($env:BREEZECTL_CONFIG) { return $env:BREEZECTL_CONFIG }
    if ($script:OnWindows) { return (Join-Path $env:APPDATA 'breezectl') }
    $base = $env:XDG_CONFIG_HOME
    if (-not $base) { $base = Join-Path $HOME '.config' }
    return (Join-Path $base 'breezectl')
}
$script:ConfigDir = Get-ConfigDir
$script:ServersDir = Join-Path $script:ConfigDir 'servers'

function Test-ValidName([string]$name) {
    return ($name -match '^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$')
}
function Get-ServerFile([string]$name) { return (Join-Path $script:ServersDir ($name + '.json')) }

function Get-ServerNames {
    if (-not (Test-Path -LiteralPath $script:ServersDir)) { return , @() }
    return , @(Get-ChildItem -LiteralPath $script:ServersDir -Filter '*.json' -File |
        Sort-Object Name | ForEach-Object { $_.BaseName })
}

function Get-CurrentName {
    if ($script:OptServer) { return $script:OptServer }
    if ($env:BREEZECTL_SERVER) { return $env:BREEZECTL_SERVER }
    $cur = Join-Path $script:ConfigDir 'current'
    if (Test-Path -LiteralPath $cur) {
        $n = (Get-Content -LiteralPath $cur -TotalCount 1)
        if ($n) { $n = $n.Trim() }
        if ($n -and (Test-Path -LiteralPath (Get-ServerFile $n))) { return $n }
    }
    $all = Get-ServerNames
    if ($all.Count -eq 1) { return $all[0] }
    return $null
}

function Protect-Text([string]$plain) {
    $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
    return (ConvertFrom-SecureString -SecureString $secure)
}
function Unprotect-Text([string]$protected) {
    $secure = ConvertTo-SecureString -String $protected
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Read-Server([string]$name) {
    $file = Get-ServerFile $name
    if (-not (Test-Path -LiteralPath $file)) { Fail "no saved server called '$name' (breezectl servers lists them)" }
    try { $data = [IO.File]::ReadAllText($file) | ConvertFrom-Json }
    catch { Fail "$file is damaged -- remove it with: breezectl logout $name" }
    $s = [ordered]@{
        Name = $name; Base = [string](Get-Field $data 'base_url'); Label = [string](Get-Field $data 'label')
        TokenId = [string](Get-Field $data 'token_id'); Key = $null; Token = $null
        Ca = [string](Get-Field $data 'ca_file')
    }
    try {
        if (Get-Field $data 'api_key_dpapi') { $s.Key = Unprotect-Text (Get-Field $data 'api_key_dpapi') }
        else { $s.Key = [string](Get-Field $data 'api_key') }
        if (Get-Field $data 'device_token_dpapi') { $s.Token = Unprotect-Text (Get-Field $data 'device_token_dpapi') }
        else { $s.Token = [string](Get-Field $data 'device_token') }
    } catch {
        Fail "the login saved as '$name' was encrypted by another Windows account or machine -- pair again: breezectl login"
    }
    if (-not $s.Base -or -not $s.Key -or -not $s.Token) { Fail "$file is incomplete -- pair again: breezectl login" }
    return $s
}

function Use-Server {
    $name = Get-CurrentName
    if (-not $name) {
        if ((Get-ServerNames).Count -eq 0) { Fail 'no server is saved yet -- pair this machine first: breezectl login' }
        Fail 'several servers are saved; pick one with: breezectl servers use NAME (or --server NAME)'
    }
    if (-not (Test-ValidName $name)) { Fail "'$name' cannot be a server name: letters, digits, dot, dash and underscore only" }
    $script:Server = Read-Server $name
    if ($script:Server.Ca) { $script:CaFile = $script:Server.Ca }
}

function Save-Server($s) {
    New-Item -ItemType Directory -Force -Path $script:ServersDir | Out-Null
    $doc = [ordered]@{ base_url = $s.Base }
    if ($script:OnWindows) {
        $doc.api_key_dpapi = Protect-Text $s.Key
        $doc.device_token_dpapi = Protect-Text $s.Token
    } else {
        $doc.api_key = $s.Key
        $doc.device_token = $s.Token
    }
    $doc.token_id = $s.TokenId
    $doc.label = $s.Label
    $doc.ca_file = [string]$s.Ca
    $doc.saved_by = "breezectl.ps1 $script:Version"
    $file = Get-ServerFile $s.Name
    $tmp = $file + '.partial'
    [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json) + "`n", (New-Object Text.UTF8Encoding($false)))
    if (-not $script:OnWindows) {
        & chmod 700 $script:ConfigDir $script:ServersDir 2>$null
        & chmod 600 $tmp 2>$null
    }
    Move-Item -LiteralPath $tmp -Destination $file -Force
}

function Set-Current([string]$name) {
    New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:ConfigDir 'current'), $name + "`n")
}

# ------------------------------------------------------------------- HTTP

Add-Type -AssemblyName System.Net.Http
# Windows PowerShell 5.1 still offers TLS 1.0 first; a server behind a modern
# proxy refuses it.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# A server with a certificate from its own CA (--ca FILE): a certificate is
# accepted when the system trusts it, or when its chain ends at that CA and is
# otherwise sound -- name, dates, usage. In C#, because HttpClient calls this on
# a thread-pool thread, where a PowerShell script block cannot run.
$script:CaHelper = @'
using System;
using System.Net.Http;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class BreezectlCa {
    public static X509Certificate2 Ca;
    static bool Check(HttpRequestMessage request, X509Certificate2 cert, X509Chain chain, SslPolicyErrors errors) {
        if (errors == SslPolicyErrors.None) return true;
        if (Ca == null || cert == null || (errors & ~SslPolicyErrors.RemoteCertificateChainErrors) != 0) return false;
        using (X509Chain own = new X509Chain()) {
            own.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            own.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
            own.ChainPolicy.ExtraStore.Add(Ca);
            if (!own.Build(cert)) return false;
            X509Certificate2 root = own.ChainElements[own.ChainElements.Count - 1].Certificate;
            return root.RawData.Length == Ca.RawData.Length && root.Thumbprint == Ca.Thumbprint;
        }
    }
    public static Func<HttpRequestMessage, X509Certificate2, X509Chain, SslPolicyErrors, bool> Callback {
        get { return Check; }
    }
}
'@

function Use-CaFile([string]$path) {
    if (-not ('BreezectlCa' -as [type])) {
        if ($PSVersionTable.PSEdition -eq 'Desktop') { Add-Type -TypeDefinition $script:CaHelper -ReferencedAssemblies System.Net.Http }
        else { Add-Type -TypeDefinition $script:CaHelper }
    }
    try {
        $bytes = [IO.File]::ReadAllBytes($path)
        # PEM is decoded here: not every .NET reads it from bytes.
        $text = [Text.Encoding]::ASCII.GetString($bytes)
        if ($text -match '-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----') {
            $bytes = [Convert]::FromBase64String(($Matches[1] -replace '\s', ''))
        }
        [BreezectlCa]::Ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $bytes)
    } catch { Fail "cannot read the certificate $path -- it should be a PEM or DER file" }
}

$script:Http = $null
function Get-HttpClient {
    if ($null -eq $script:Http) {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
        if ($script:CaFile) {
            Use-CaFile $script:CaFile
            $handler.ServerCertificateCustomValidationCallback = [BreezectlCa]::Callback
        }
        $script:Http = New-Object System.Net.Http.HttpClient($handler)
        $timeout = 60
        if ($env:BREEZECTL_TIMEOUT) { $timeout = [int]$env:BREEZECTL_TIMEOUT }
        $script:Http.Timeout = [TimeSpan]::FromSeconds($timeout)
        $script:Http.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', "breezectl.ps1/$script:Version") | Out-Null
    }
    return $script:Http
}

# Invoke-Api METHOD PATH [BODY-OBJECT] [-Base URL] [-Key K] [-Token T]
# Returns @{ Ok; Status; Ms; Body (parsed, or $null); Raw; Error }.
function Invoke-Api {
    param([string]$Method, [string]$Path, $Body = $null, [string]$Base, [string]$Key, [string]$Token, [switch]$NoAuth)
    if (-not $Base) { $Base = $script:Server.Base }
    if (-not $NoAuth) {
        if (-not $PSBoundParameters.ContainsKey('Key')) { $Key = $script:Server.Key }
        if (-not $PSBoundParameters.ContainsKey('Token')) { $Token = $script:Server.Token }
    }
    $request = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), ($Base + $Path))
    $request.Headers.TryAddWithoutValidation('Accept', 'application/json') | Out-Null
    if ($Key) { $request.Headers.TryAddWithoutValidation('X-API-Key', $Key) | Out-Null }
    if ($Token) { $request.Headers.TryAddWithoutValidation('Authorization', "Bearer $Token") | Out-Null }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Compress -Depth 8
        $request.Content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $r = @{ Ok = $false; Status = 0; Ms = 0; Body = $null; Raw = ''; Error = '' }
    try {
        $response = (Get-HttpClient).SendAsync($request).GetAwaiter().GetResult()
    } catch {
        $r.Error = Get-TransportError $_.Exception $Base
        return $r
    } finally {
        $request.Dispose()
    }
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $watch.Stop()
    $r.Ms = [int]$watch.ElapsedMilliseconds
    $r.Status = [int]$response.StatusCode
    $r.Raw = [Text.Encoding]::UTF8.GetString($bytes)
    $response.Dispose()
    if ($r.Raw.Trim()) {
        try { $r.Body = $r.Raw | ConvertFrom-Json }
        catch {
            $r.Error = "the server's answer was not JSON (HTTP $($r.Status)) -- is $Base a Breeze Core server?"
            return $r
        }
    }
    if ($r.Status -ge 200 -and $r.Status -lt 300) { $r.Ok = $true; return $r }
    $r.Error = Get-Explanation $r
    return $r
}

function Get-TransportError($exception, [string]$base) {
    $e = $exception
    while ($e.InnerException) { $e = $e.InnerException }
    $all = $exception.ToString()
    if ($exception -is [System.Threading.Tasks.TaskCanceledException] -or $all -match 'TimeoutException|timed out|Timeout') {
        return "$base did not answer in time"
    }
    if ($all -match 'AuthenticationException|SSL|TLS|certificate') {
        return "the secure connection to $base failed: $($e.Message)`n  (a server with its own certificate: pair with --ca FILE)"
    }
    if ($all -match 'No such host|nodename nor servname|Name or service not known|The remote name could not be resolved|No such device or address') {
        return "cannot find $base -- check the address"
    }
    if ($all -match 'refused|actively refused|Unable to connect|Connection refused') {
        return "cannot connect to $base -- is the server running, and is the address right?"
    }
    return "could not reach ${base}: $($e.Message)"
}

# The reason in a failed response -- a plain string, or the auth layer's object
# with its own detail inside -- and what it usually means.
function Get-Explanation($r) {
    $detail = $null
    $d = Get-Field $r.Body 'detail'
    if ($d -is [string]) { $detail = $d }
    elseif ($null -ne $d) {
        $detail = Get-Field $d 'detail'
        if (-not $detail) { $detail = Get-Field $d 'error' }
    }
    if (-not $detail) {
        $detail = ($r.Raw -replace '[\r\n]+', ' ')
        if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
    }
    if (-not $detail) { $detail = 'no reason given' }
    switch ($r.Status) {
        401 { return "$detail`n  (run ``breezectl login`` to pair this machine again)" }
        403 { return "$detail`n  (that has to come from the server's local network)" }
        404 { return $detail }
        503 { return "$detail`n  (the unit did not answer -- is it powered and on the network?)" }
        default { return "$detail [HTTP $($r.Status)]" }
    }
}

function Invoke-ApiOrFail {
    param([string]$Method, [string]$Path, $Body = $null)
    $r = Invoke-Api -Method $Method -Path $Path -Body $Body
    if (-not $r.Ok) { Fail $r.Error }
    return $r
}

# A bare host or address is assumed to be the server's own port on plain HTTP,
# which is how it ships.
function ConvertTo-BaseUrl([string]$text) {
    $u = ($text -replace '\s', '').TrimEnd('/')
    if ($u -notmatch '^https?://') {
        if ($u -match ':\d+$') { $u = 'http://' + $u } else { $u = 'http://' + $u + ':8420' }
    }
    return $u
}

# ------------------------------------------------------- control: parsing
#
# Positional, as `breeze-core control` is, with its words and its messages, so
# a script written for one runs with the other.

function Test-Skipped([string]$w) { return @('none', '-', '', 'same', 'keep') -contains $w }

function Get-TimerMinutes([string]$w) {
    if ($w -cmatch '^([0-9]+)([a-z]+)$') {
        $n = [int64]$Matches[1]
        switch ($Matches[2]) {
            { @('m', 'min', 'mins', 'minute', 'minutes') -contains $_ } { return $n }
            { @('h', 'hr', 'hrs', 'hour', 'hours') -contains $_ } { return $n * 60 }
        }
    }
    return $null
}

function Format-Number([double]$v) { return $v.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture) }

function ConvertTo-Temperature([string]$w) {
    $t = $w.TrimEnd('c', 'C', [char]0x00B0)
    $v = 0.0
    if ($t -notmatch '^[0-9]+(\.[0-9]+)?$' -or -not [double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
        UsageFail "'$w' is not a temperature"
    }
    if ($v -lt 16 -or $v -gt 30) { UsageFail "$(Format-Number $v) is outside the 16-30 $script:Deg the API accepts" }
    if (($v * 2) -ne [math]::Floor($v * 2)) { UsageFail "$(Format-Number $v) is not a whole or half degree" }
    return $v
}

function ConvertTo-Flap([string]$w) {
    switch ($w) {
        { @('both', 'all') -contains $_ } { return 'BOTH' }
        { @('horizontal', 'h', 'lr', 'leftright') -contains $_ } { return 'HORIZONTAL' }
        { @('vertical', 'v', 'ud', 'updown') -contains $_ } { return 'VERTICAL' }
        { @('off', 'still', 'fixed') -contains $_ } { return 'OFF' }
    }
    UsageFail "'$w' is not a flap setting. Use both, horizontal, vertical, off or none"
}

function ConvertTo-Fan([string]$w) {
    switch ($w) {
        { @('silent', 'quiet') -contains $_ } { return 20 }
        { @('low', 'l') -contains $_ } { return 40 }
        { @('medium', 'med', 'm') -contains $_ } { return 60 }
        { @('high', 'h') -contains $_ } { return 80 }
        { @('max', 'full') -contains $_ } { return 100 }
        { @('auto', 'a') -contains $_ } { return 102 }
    }
    $n = $w.TrimEnd('%')
    if ($n -notmatch '^[0-9]+$') { UsageFail "'$w' is not a fan speed. Use silent, low, medium, high, max, auto, none, or a percentage" }
    $v = [int64]$n
    if (@(20, 40, 60, 80, 100, 102) -notcontains $v) { UsageFail "$v is not one of the speeds the API accepts (20, 40, 60, 80, 100, 102)" }
    return [int]$v
}

function Read-ControlWords([string[]]$words) {
    $c = [ordered]@{}
    $timer = $null
    if ($words.Count -gt 6) { UsageFail "too many arguments: expected at most TYPE TEMPERATURE FLAP FAN EXTRA TIMER, got $($words.Count)" }
    $index = 0
    foreach ($word in $words) {
        $lower = $word.ToLowerInvariant()
        $minutes = Get-TimerMinutes $lower
        if ($null -ne $minutes) {
            if ($null -ne $timer) { UsageFail 'two timers were given' }
            $timer = $minutes
            continue
        }
        if (-not (Test-Skipped $lower)) {
            switch ($index) {
                0 {
                    switch ($lower) {
                        'off' { $c.power_state = $false }
                        'on' { $c.power_state = $true }
                        default {
                            $mode = $null
                            if (@('cool', 'cooling') -contains $lower) { $mode = 'COOL' }
                            elseif (@('heat', 'heating') -contains $lower) { $mode = 'HEAT' }
                            elseif (@('dry', 'dehumidify') -contains $lower) { $mode = 'DRY' }
                            elseif ($lower -eq 'auto') { $mode = 'AUTO' }
                            elseif (@('fan', 'fan_only', 'fanonly', 'ventilate') -contains $lower) { $mode = 'FAN_ONLY' }
                            else { UsageFail "'$lower' is not a mode. Use cool, heat, dry, auto, fan, on, off or none" }
                            # A mode implies running: setting one on a unit
                            # that stays off is never what was meant.
                            $c.power_state = $true
                            $c.operational_mode = $mode
                        }
                    }
                }
                1 { $c.target_temperature = ConvertTo-Temperature $lower }
                2 { $c.swing_mode = ConvertTo-Flap $lower }
                3 { $c.fan_speed = ConvertTo-Fan $lower }
                4 {
                    foreach ($part in ($lower -split '[+,]')) {
                        switch ($part.Trim()) {
                            '' { }
                            { @('turbo', 'boost') -contains $_ } { $c.turbo = $true }
                            { @('eco', 'saving') -contains $_ } { $c.eco = $true }
                            { @('noturbo', 'no-turbo') -contains $_ } { $c.turbo = $false }
                            { @('noeco', 'no-eco') -contains $_ } { $c.eco = $false }
                            default { UsageFail "'$($part.Trim())' is not an extra. Use turbo, eco, no-turbo, no-eco or none" }
                        }
                    }
                }
                default { UsageFail "'$word' is one argument too many" }
            }
        }
        $index++
    }
    # The server CLI's field order, so the two send the same bytes.
    $body = [ordered]@{}
    foreach ($k in @('power_state', 'operational_mode', 'target_temperature', 'swing_mode', 'fan_speed', 'eco', 'turbo')) {
        if ($c.Contains($k)) { $body[$k] = $c[$k] }
    }
    return @{ Body = $body; Timer = $timer }
}

# --------------------------------------------- what a unit says, in words

function Format-Temperature($v) {
    if ($null -eq $v -or -not ($v -is [ValueType])) { return '--' }
    return ([double]$v).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
}

function Format-Fan($n) {
    switch ([int]$n) { 20 { 'silent' } 40 { 'low' } 60 { 'medium' } 80 { 'high' } 100 { 'max' } 102 { 'auto' } default { "$n%" } }
}

# One line of what the unit reports. Off, it still says what it is set to, so
# a change made while it is off is confirmed. Lower-case: some screen readers
# spell an all-capitals word out.
function Get-Description($state) {
    $mode = Get-Field $state 'operational_mode'
    if ($mode -is [string]) { $mode = $mode.ToLowerInvariant().Replace('_', ' ') } else { $mode = '?' }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($mode)
    $parts.Add("$(Format-Temperature (Get-Field $state 'target_temperature')) $script:Deg")
    $swing = Get-Field $state 'swing_mode'
    if ($swing -is [string] -and $swing -ne 'OFF') { $parts.Add("swing $($swing.ToLowerInvariant())") }
    $fan = Get-Field $state 'fan_speed'
    if ($null -ne $fan -and $fan -is [ValueType]) { $parts.Add("fan $(Format-Fan $fan)") }
    if ((Get-Field $state 'eco') -eq $true) { $parts.Add('eco') }
    if ((Get-Field $state 'turbo') -eq $true) { $parts.Add('turbo') }
    $indoor = "indoor $(Format-Temperature (Get-Field $state 'indoor_temperature')) $script:Deg"
    if ((Get-Field $state 'power_state') -eq $false) { return "off, set to $($parts -join ', '); $indoor" }
    $parts.Add($indoor)
    return ($parts -join ', ')
}

# The fields a unit did not take, as a sentence with the reasons measured on
# real units -- the panel's, the app's and the server CLI's own wording.
function Get-NotApplied($state) {
    $fields = @(As-List (Get-Field $state 'not_applied') | Where-Object { $_ -is [string] })
    if ($fields.Count -eq 0) { return $null }
    $names = foreach ($f in $fields) {
        switch ($f) {
            'swing_mode' { 'the flap change' } 'fan_speed' { 'the fan speed' }
            'target_temperature' { 'the temperature' } 'operational_mode' { 'the mode' }
            'power_state' { 'the power change' } default { $f.Replace('_', ' ') }
        }
    }
    $names = @($names)
    if ($names.Count -eq 1) { $joined = $names[0] }
    else { $joined = ($names[0..($names.Count - 2)] -join ', ') + ' and ' + $names[-1] }
    $on = (Get-Field $state 'power_state') -eq $true
    $heating = (Get-Field $state 'operational_mode') -eq 'HEAT'
    $reasons = New-Object System.Collections.Generic.List[string]
    foreach ($f in $fields) {
        if ($f -eq 'swing_mode' -and -not $on) { $why = 'Units only move their flaps while they are running.' }
        elseif ($f -eq 'swing_mode' -and $heating) { $why = 'While heating, it holds its flaps still until warm air is coming out, which can take a few minutes after switching on or into heating. Try again shortly.' }
        elseif ($f -eq 'swing_mode') { $why = 'It may need a moment before it will take this. Try again shortly.' }
        elseif ($f -eq 'eco' -and $heating) { $why = 'Many units offer eco only while cooling, not while heating.' }
        elseif ($f -eq 'eco') { $why = 'Many units offer eco only in some modes.' }
        elseif ($f -eq 'turbo') { $why = 'Many units offer turbo only in some modes.' }
        else { $why = 'It does not take this in its current mode.' }
        if (-not $reasons.Contains($why)) { $reasons.Add($why) }
    }
    return "the air conditioner didn't accept $joined; the unit refused it, not Breeze Core. $($reasons -join ' ')"
}

# ------------------------------------------------------------- finding a unit

# An id first (for scripts), then a unique case-insensitive name, then a
# unique prefix. Ambiguity lists the candidates rather than picking one.
function Resolve-Unit($units, [string]$wanted) {
    $list = @(As-List $units)
    if ($list.Count -eq 0) { Fail 'this server has no units configured' }
    $w = $wanted.Trim()
    $lw = $w.ToLowerInvariant()
    foreach ($u in $list) { if ([string](Get-Field $u 'id') -eq $w) { return $u } }
    $exact = @($list | Where-Object { ([string](Get-Field $_ 'name')).ToLowerInvariant() -eq $lw })
    if ($exact.Count -eq 1) { return $exact[0] }
    if ($exact.Count -gt 1) { Fail "'$wanted' matches $($exact.Count) units by name; use an id instead" }
    $pre = @($list | Where-Object { ([string](Get-Field $_ 'name')).ToLowerInvariant().StartsWith($lw, [StringComparison]::Ordinal) })
    if ($pre.Count -eq 1) { return $pre[0] }
    if ($pre.Count -gt 1) { Fail "'$wanted' is ambiguous -- it could be $((@($pre | ForEach-Object { Get-Field $_ 'name' })) -join ' or ')" }
    Fail "no unit matches '$wanted'. Known units: $((@($list | ForEach-Object { Get-Field $_ 'name' })) -join ', ')"
}

function Get-Units {
    $units = (Invoke-ApiOrFail GET '/api/units').Body
    Save-UnitCache $units
    return $units
}

# The units' names, one per line, for tab completion, which reads this file
# rather than asking the server at every Tab. Refreshed whenever the units
# are fetched anyway; losing it costs nothing.
function Get-UnitCacheFile([string]$name) { return (Join-Path (Join-Path $script:ConfigDir 'cache') ($name + '.units')) }
function Save-UnitCache($units) {
    try {
        $file = Get-UnitCacheFile $script:Server.Name
        New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
        $names = @(@(As-List $units) | ForEach-Object { [string](Get-Field $_ 'name') })
        $text = ''
        if ($names.Count -gt 0) { $text = ($names -join "`n") + "`n" }
        [IO.File]::WriteAllText($file + '.partial', $text, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath ($file + '.partial') -Destination $file -Force
    } catch { }
}

# breezectl __complete servers|units -- for tab completion: the saved servers,
# or the units of the current one. Prints nothing rather than an error. The
# server is asked only when no list of units has been seen yet, and briefly.
function Invoke-Complete([string[]]$a) {
    if ($a.Count -lt 1) { return }
    switch ($a[0]) {
        'servers' { foreach ($n in (Get-ServerNames)) { Say $n } }
        'units' {
            $name = Get-CurrentName
            if (-not $name -or -not (Test-ValidName $name)) { return }
            $file = Get-UnitCacheFile $name
            if (-not (Test-Path -LiteralPath $file)) {
                try { $env:BREEZECTL_TIMEOUT = '3'; Use-Server; Get-Units | Out-Null } catch { }
            }
            if (Test-Path -LiteralPath $file) {
                foreach ($line in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) { if ($line) { Say $line } }
            }
        }
    }
}

# ------------------------------------------------------------- the commands

function Invoke-Control([string[]]$a) {
    if ($a.Count -lt 1) { Show-Usage; Fail '' 2 }
    $name = $a[0]
    $rest = @()
    if ($a.Count -gt 1) { $rest = $a[1..($a.Count - 1)] }
    # A name and nothing else asks how that unit is.
    if ($rest.Count -eq 0) { Invoke-Status @($name); return }
    $parsed = Read-ControlWords $rest
    if ($parsed.Body.Count -eq 0 -and $null -eq $parsed.Timer) { UsageFail "nothing to do -- every setting was 'none'" }
    Use-Server
    $unit = Resolve-Unit (Get-Units) $name
    $id = [string](Get-Field $unit 'id'); $uname = [string](Get-Field $unit 'name')
    if ($parsed.Body.Count -gt 0) {
        $r = Invoke-ApiOrFail POST "/api/units/$id/control" $parsed.Body
        Say "${uname}: $(Get-Description $r.Body)"
        # Still exit 0 when the unit refused a part: the request was carried
        # out; the unit chose -- as the server CLI does.
        $refused = Get-NotApplied $r.Body
        if ($refused) { Say "${uname}: $refused" }
    }
    if ($null -ne $parsed.Timer) { New-SleepTimer $id $uname $parsed.Timer }
}

function New-SleepTimer([string]$id, [string]$name, [int64]$minutes) {
    $r = Invoke-ApiOrFail POST '/api/timers' ([ordered]@{ unit_ids = @($id); minutes = $minutes; label = 'breezectl' })
    Say "${name}: switching off in $minutes minutes$(Get-AtPhrase (Get-Field $r.Body 'fires_at') ($minutes * 60))"
}

# The server's times are naive local ISO strings. PowerShell 7 turns such a
# string into a [datetime] as it reads the JSON; the digits survive, so this
# writes them back out the way the server sent them.
function Get-IsoText($value) {
    if ($value -is [datetime]) { return $value.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
    return [string]$value
}

function Get-AtPhrase($firesAt, [int64]$seconds) {
    if (-not $firesAt) { return '' }
    $s = Get-IsoText $firesAt
    if ($s.Length -lt 16) { return '' }
    if ($seconds -lt 43200) { return ", at $($s.Substring(11, 5))" }
    return ", at $($s.Substring(11, 5)) on $($s.Substring(0, 10))"
}

function Invoke-Status([string[]]$names) {
    Use-Server
    if ($names.Count -gt 0) {
        $units = Get-Units
        foreach ($n in $names) {
            $u = Resolve-Unit $units $n
            $uname = [string](Get-Field $u 'name')
            $r = Invoke-Api GET "/api/units/$(Get-Field $u 'id')/state"
            if (-not $r.Ok) { Say "${uname}: did not answer -- $($r.Error)" }
            elseif ((Get-Field $r.Body 'online') -eq $false) { Say "${uname}: offline" }
            else { Say "${uname}: $(Get-Description $r.Body)" }
        }
        return
    }
    $env = (Invoke-ApiOrFail GET '/api/units/state').Body
    $states = @(As-List (Get-Field $env 'states'))
    $errors = @(As-List (Get-Field $env 'errors'))
    if ($states.Count -eq 0 -and $errors.Count -eq 0) {
        Say 'This server has no units yet. Add them in the web panel, or on the server: breeze-core pair'
        return
    }
    foreach ($s in $states) {
        if ((Get-Field $s 'online') -eq $false) { Say "$(Get-Field $s 'name'): offline" }
        else { Say "$(Get-Field $s 'name'): $(Get-Description $s)" }
    }
    foreach ($e in $errors) {
        $why = Get-Field $e 'error'; if (-not $why) { $why = 'no reason given' }
        Say "$(Get-Field $e 'name'): did not answer -- $why"
    }
}

function Invoke-Units {
    Use-Server
    $list = @(As-List (Get-Units))
    if ($list.Count -eq 0) { Say 'This server has no units yet.'; return }
    $w = ($list | ForEach-Object { ([string](Get-Field $_ 'name')).Length } | Measure-Object -Maximum).Maximum
    foreach ($u in $list) { Say ("{0}  {1}" -f ([string](Get-Field $u 'name')).PadRight($w), (Get-Field $u 'id')) }
}

# ----------------------------------------------------------------- timers

function Format-Remaining([int64]$s) {
    if ($s -lt 60) { return 'in under a minute' }
    # Up to the next minute, as the server rounds its own "minutes".
    $s = [int64]([math]::Ceiling($s / 60.0) * 60)
    $d = [math]::Floor($s / 86400); $h = [math]::Floor(($s % 86400) / 3600); $m = [math]::Floor(($s % 3600) / 60)
    if ($d -gt 0) { $t = "in $d $(if ($d -eq 1) { 'day' } else { 'days' })"; if ($h) { $t += " $h h" }; return $t }
    if ($h -gt 0) { $t = "in $h h"; if ($m) { $t += " $m min" }; return $t }
    return "in $m min"
}

function Get-Timers { return @(As-List (Invoke-ApiOrFail GET '/api/timers?kind=all').Body) }

function Invoke-Timers([string[]]$a) {
    $sub = 'list'
    if ($a.Count -gt 0) { $sub = $a[0]; $a = @($a | Select-Object -Skip 1) }
    switch ($sub) {
        { @('list', 'ls') -contains $_ } { Show-Timers; return }
        { @('cancel', 'rm', 'delete') -contains $_ } { Remove-Timers $a; return }
        'off' {
            if ($a.Count -ne 2) { UsageFail "usage: breezectl timers off 'NAME' 30m" }
            $m = Get-TimerMinutes $a[1].ToLowerInvariant()
            if ($null -eq $m) { UsageFail "'$($a[1])' is not a duration (15m, 90min, 2h)" }
            Use-Server
            $u = Resolve-Unit (Get-Units) $a[0]
            New-SleepTimer ([string](Get-Field $u 'id')) ([string](Get-Field $u 'name')) $m
            return
        }
        { @('start', 'on') -contains $_ } { New-StartTimer $a; return }
        default { UsageFail "unknown timers command '$sub' -- list, off, start or cancel" }
    }
}

function Show-Timers {
    Use-Server
    $units = @(As-List (Get-Units))
    $names = @{}
    foreach ($u in $units) { $names[[string](Get-Field $u 'id')] = [string](Get-Field $u 'name') }
    $timers = @(Get-Timers)
    if ($timers.Count -eq 0) { Say 'No timers are pending.'; return }
    foreach ($t in $timers) {
        $ids = @(As-List (Get-Field $t 'unit_ids'))
        $who = @($ids | ForEach-Object { if ($names.ContainsKey([string]$_)) { $names[[string]$_] } else { [string]$_ } })
        if ($who.Count -eq 0) { $whoText = 'every unit' }
        elseif ($who.Count -eq 1) { $whoText = $who[0] }
        else { $whoText = ($who[0..($who.Count - 2)] -join ', ') + ' and ' + $who[-1] }
        $settings = Get-Field $t 'settings'
        $power = Get-Field $settings 'power_state'
        if ($power -eq $true) { $what = 'switches on' } else { $what = 'switches off' }
        $extra = ''
        $mode = Get-Field $settings 'operational_mode'; if ($mode) { $extra += ", $($mode.ToLowerInvariant())" }
        $tt = Get-Field $settings 'target_temperature'; if ($null -ne $tt) { $extra += ", $(Format-Temperature $tt) $script:Deg" }
        if ((Get-Field $settings 'eco') -eq $true) { $extra += ', eco' }
        if ((Get-Field $settings 'turbo') -eq $true) { $extra += ', turbo' }
        if ($extra -and $null -eq $power) { $what = 'changes' }
        $s = [int64](Get-Field $t 'seconds_remaining')
        $at = Get-AtPhrase (Get-Field $t 'fires_at') $s
        Say "${whoText}: $what$extra $(Format-Remaining $s)$at (timer $(Get-Field $t 'id'))"
    }
}

function Remove-Timers([string[]]$a) {
    if ($a.Count -ne 1) { UsageFail "usage: breezectl timers cancel ID|'NAME'|all" }
    Use-Server
    $timers = @(Get-Timers)
    $want = $a[0]
    $chosen = @($timers | Where-Object { $want -eq 'all' -or [string](Get-Field $_ 'id') -eq $want })
    if ($chosen.Count -eq 0 -and $want -ne 'all') {
        $u = Resolve-Unit (Get-Units) $want
        $id = [string](Get-Field $u 'id')
        $chosen = @($timers | Where-Object { @(As-List (Get-Field $_ 'unit_ids')) -contains $id })
        if ($chosen.Count -eq 0) {
            if (@($timers | Where-Object { @(As-List (Get-Field $_ 'unit_ids')).Count -eq 0 }).Count -gt 0) {
                Fail "no timer names $(Get-Field $u 'name'), but a timer for every unit is pending -- cancel it by id (breezectl timers)"
            }
            Say "No timer is pending for $(Get-Field $u 'name')."
            return
        }
    }
    if ($chosen.Count -eq 0) { Say 'No timers are pending.'; return }
    foreach ($t in $chosen) {
        $tid = [string](Get-Field $t 'id')
        if ($tid -notmatch '^[A-Za-z0-9_-]+$') { Fail "unexpected timer id '$tid'" }
        Invoke-ApiOrFail DELETE "/api/timers/$tid" | Out-Null
        Say "Cancelled timer $tid."
    }
}

function New-StartTimer([string[]]$a) {
    if ($a.Count -lt 2 -or $a.Count -gt 3) { UsageFail "usage: breezectl timers start 'NAME' 07:30 [tomorrow|DAYS]" }
    if ($a[1] -match '^([01]?[0-9]|2[0-3]):([0-5][0-9])$') { $at = '{0:00}:{1}' -f [int]$Matches[1], $Matches[2] }
    else { UsageFail "'$($a[1])' is not a time -- use HH:MM, 24-hour, on the server's clock" }
    $days = 0
    if ($a.Count -eq 3) {
        $d = $a[2].ToLowerInvariant()
        if ($d -eq 'today') { $days = 0 }
        elseif ($d -eq 'tomorrow') { $days = 1 }
        elseif ($d -match '^[0-9]+$') { $days = [int]$d; if ($days -gt 30) { UsageFail 'a start can be at most 30 days ahead' } }
        else { UsageFail "'$($a[2])' is not a number of days (0-30), today or tomorrow" }
    }
    Use-Server
    $u = Resolve-Unit (Get-Units) $a[0]
    $r = Invoke-ApiOrFail POST '/api/timers' ([ordered]@{ unit_ids = @([string](Get-Field $u 'id')); at = $at; days = $days; label = 'breezectl' })
    $f = Get-IsoText (Get-Field $r.Body 'fires_at')
    if ($f.Length -lt 16) { Fail 'the server set the timer but did not say when it fires' }
    Say "$(Get-Field $u 'name'): switching on at $($f.Substring(11, 5)) on $($f.Substring(0, 10)), in the mode and at the temperature it last had"
}

# ------------------------------------------------- pairing: login, logout

function Test-Interactive { return (-not $script:OptYes) -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected }

function Read-Answer([string]$prompt, [string]$default = '') {
    $answer = Read-Host -Prompt $prompt
    if (-not $answer) { return $default }
    return $answer
}

function Read-SecretAnswer([string]$prompt) {
    $secure = Read-Host -Prompt $prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Invoke-Login([string[]]$a) {
    $url = $null; $name = $null; $label = $null; $keyStdin = $false
    for ($i = 0; $i -lt $a.Count; $i++) {
        # Every clause breaks: a switch runs all the clauses that match, and
        # the catch-all for unknown options matches the known ones too.
        switch ($a[$i]) {
            '--name' { $i++; if ($i -ge $a.Count) { UsageFail '--name needs a value' }; $name = $a[$i]; break }
            '--label' { $i++; if ($i -ge $a.Count) { UsageFail '--label needs a value' }; $label = $a[$i]; break }
            '--key-stdin' { $keyStdin = $true; break }
            '--ca' { $i++; if ($i -ge $a.Count) { UsageFail '--ca needs a file' }; $script:CaFile = $a[$i]; break }
            { @('--yes', '-y') -contains $_ } { $script:OptYes = $true; break }
            { $_ -like '-*' } { UsageFail "unknown option $($a[$i])" }
            default { if ($url) { UsageFail 'one server address at a time' }; $url = $a[$i] }
        }
    }
    if ($script:CaFile) {
        if (-not (Test-Path -LiteralPath $script:CaFile -PathType Leaf)) { Fail "cannot read the certificate $($script:CaFile)" }
        $script:CaFile = (Resolve-Path -LiteralPath $script:CaFile).ProviderPath
    }
    $key = $null
    if ($keyStdin) {
        $key = [Console]::In.ReadLine()
        if ($key) { $key = $key.Trim() }
        if (-not $key) { Fail '--key-stdin: nothing arrived on standard input' }
    }

    Say 'Pairing this machine with a Breeze Core server.'
    while ($true) {
        if (-not $url) {
            if (-not (Test-Interactive)) { Fail "give the server's address: breezectl login URL" }
            $url = Read-Answer 'Server address (e.g. 192.168.1.10 or https://breeze.example.com)'
            if (-not $url) { continue }
        }
        $base = ConvertTo-BaseUrl $url
        $r = Invoke-Api GET '/api/health' -Base $base -NoAuth
        if ($r.Ok -and (Get-Field $r.Body 'status') -eq 'ok') { Say "Found a Breeze Core server at $base."; break }
        $why = $r.Error; if (-not $why) { $why = "$base answered, but not as a Breeze Core server does" }
        if (-not (Test-Interactive)) { Fail $why }
        [Console]::Error.WriteLine("breezectl: $why")
        $url = $null
    }

    $tries = 0
    while ($true) {
        if (-not $key) {
            if (-not (Test-Interactive)) { Fail 'give the API key on standard input: --key-stdin' }
            Say "The API key is in the server's config.json (`"api_key`"), or ask whoever runs it."
            $key = (Read-SecretAnswer 'API key (not shown as you type)').Trim()
            if (-not $key) { continue }
        }
        $r = Invoke-Api GET '/api/version' -Base $base -Key $key -Token ''
        if ($r.Ok) { Say "The key is right. The server runs Breeze Core $(Get-Field $r.Body 'version')."; break }
        if ($r.Status -ne 401) { Fail $r.Error }
        $tries++
        if (-not (Test-Interactive) -or $tries -ge 3) { Fail 'the server refused that API key' }
        [Console]::Error.WriteLine('breezectl: the server refused that API key')
        $key = $null
    }

    if (-not $label) { $label = "breezectl on $([Environment]::MachineName)" }
    if (Test-Interactive) { $label = Read-Answer "Name this device on the server [$label]" $label }
    if (-not $name) {
        $name = (([uri]$base).Host -replace '[^A-Za-z0-9._-]', '-')
        if (-not (Test-ValidName $name)) { $name = 'server' }
        if (Test-Interactive) { $name = Read-Answer "Save this server as [$name]" $name }
    }
    if (-not (Test-ValidName $name)) { Fail "'$name' cannot be a name: letters, digits, dot, dash and underscore only" }
    if (Test-Path -LiteralPath (Get-ServerFile $name)) {
        if (Test-Interactive) {
            $yn = Read-Answer "A server called '$name' is already saved. Replace it? [y/N]" 'n'
            if ($yn -notmatch '^[yY]') { Fail "kept the existing '$name'; choose another name with --name" }
        } elseif (-not $script:OptYes) {
            Fail "a server called '$name' is already saved -- choose another --name, or --yes to replace it"
        }
        Say 'Note: the old pairing stays valid on the server until it is revoked there.'
    }

    $r = Invoke-Api POST '/api/auth/enroll/start' ([ordered]@{ label = $label; auth_version = 1 }) -Base $base -Key $key -Token ''
    if (-not $r.Ok) { Fail $r.Error }
    $session = Get-Field $r.Body 'session_id'; $code = Get-Field $r.Body 'user_code'
    $ttl = [int](Get-Field $r.Body 'expires_in'); if (-not $ttl) { $ttl = 60 }
    if (-not $session -or -not $code) { Fail 'the server did not start a pairing' }

    Say ''
    Say "Pairing code: $code"
    $r = Invoke-Api POST '/api/auth/enroll/approve' ([ordered]@{ code = $code }) -Base $base -Key $key -Token ''
    if ($r.Ok) { Say "Approved from here: this machine is on the server's local network." }
    else {
        Say "It has to be approved on the server's local network, within $ttl seconds:"
        Say '  in the web panel, which shows the code to approve, or'
        Say "  on the server:  breeze-core approve $code"
        Say 'Waiting for the approval... (Ctrl-C to give up)'
    }
    $waited = 0; $said = 0
    while ($true) {
        $r = Invoke-Api POST '/api/auth/enroll/poll' ([ordered]@{ session_id = $session }) -Base $base -Key $key -Token ''
        if (-not $r.Ok) { Fail $r.Error }
        $status = Get-Field $r.Body 'status'
        if ($status -ne 'pending') { break }
        if ($waited -ge ($ttl + 5)) { $status = 'expired'; break }
        Start-Sleep -Seconds 2
        $waited += 2
        # Every 15 seconds, not every tick: a screen reader reads every line.
        if (($waited - $said) -ge 15) { Say "  still waiting, about $([math]::Max(0, $ttl - $waited)) seconds left"; $said = $waited }
    }
    if ($status -ne 'approved') { Fail "the pairing was not approved (status: $status) -- run breezectl login to try again" }
    $token = Get-Field $r.Body 'device_token'
    if (-not $token) { Fail 'the server approved the pairing but issued no token' }
    $server = [ordered]@{ Name = $name; Base = $base; Key = $key; Token = $token; TokenId = [string](Get-Field $r.Body 'token_id'); Label = $label; Ca = $script:CaFile }
    Save-Server $server
    if (-not (Get-CurrentName) -or (Get-ServerNames).Count -eq 1) { Set-Current $name }
    $script:Server = $server
    $r = Invoke-Api GET '/api/auth/whoami'
    if (-not $r.Ok) { Fail "paired and saved, but the server does not accept the new token: $($r.Error)" }
    Say "Paired as `"$(Get-Field $r.Body 'label')`". Saved as '$name' in $script:ServersDir."
    if ((Get-CurrentName) -ne $name) { Say "Use it with: breezectl --server $name ...  or make it the default: breezectl servers use $name" }
    Say 'Try: breezectl status'
}

# Revoking is allowed only from the server's local network. From anywhere else
# the login is still forgotten here, and the message says how to revoke it --
# a forgotten token that still works is the case worth warning about.
function Invoke-Logout([string[]]$a) {
    if ($a.Count -gt 1) { UsageFail 'usage: breezectl logout [NAME]' }
    if ($a.Count -eq 1) { $script:OptServer = $a[0] }
    Use-Server
    $s = $script:Server
    if ($s.TokenId) {
        if ($s.TokenId -notmatch '^[A-Za-z0-9_-]+$') { Fail "unexpected token id '$($s.TokenId)'" }
        $r = Invoke-Api DELETE "/api/auth/devices/$($s.TokenId)"
        if ($r.Ok) { Say "Revoked `"$($s.Label)`" on the server." }
        elseif ($r.Status -eq 404) { Say 'The server no longer knew this pairing; nothing to revoke.' }
        else {
            Say "Not revoked on the server: $(($r.Error -split "`n")[0])"
            Say "Revoke `"$($s.Label)`" there yourself: in the web panel's device list, or on the server:"
            Say "  breeze-core revoke $($s.TokenId)"
        }
    } else {
        Say "This login has no token id to revoke; revoke `"$($s.Label)`" in the web panel if it is still listed."
    }
    Remove-Item -LiteralPath (Get-ServerFile $s.Name) -Force
    Remove-Item -LiteralPath (Get-UnitCacheFile $s.Name) -Force -ErrorAction SilentlyContinue
    $cur = Join-Path $script:ConfigDir 'current'
    if ((Test-Path -LiteralPath $cur) -and ((Get-Content -LiteralPath $cur -TotalCount 1) -eq $s.Name)) { Remove-Item -LiteralPath $cur -Force }
    Say "Forgot '$($s.Name)'."
}

function Invoke-Servers([string[]]$a) {
    $sub = 'list'
    if ($a.Count -gt 0) { $sub = $a[0]; $a = @($a | Select-Object -Skip 1) }
    switch ($sub) {
        { @('list', 'ls') -contains $_ } {
            $all = Get-ServerNames
            if ($all.Count -eq 0) { Say 'No servers are saved. Pair one with: breezectl login'; return }
            $cur = Get-CurrentName
            foreach ($n in $all) {
                try { $d = [IO.File]::ReadAllText((Get-ServerFile $n)) | ConvertFrom-Json; $u = Get-Field $d 'base_url'; $l = Get-Field $d 'label' }
                catch { $u = '(damaged file)'; $l = $null }
                $mark = ' '; if ($n -eq $cur) { $mark = '*' }
                $line = "$mark $n  $u"
                if ($l) { $line += "  paired as `"$l`"" }
                Say $line
            }
            if ($cur) { Say '(* is the default)' }
        }
        'use' {
            if ($a.Count -ne 1) { UsageFail 'usage: breezectl servers use NAME' }
            if (-not (Test-Path -LiteralPath (Get-ServerFile $a[0]))) { Fail "no saved server called '$($a[0])' (breezectl servers lists them)" }
            Set-Current $a[0]; Say "'$($a[0])' is now the default."
        }
        'rename' {
            if ($a.Count -ne 2) { UsageFail 'usage: breezectl servers rename OLD NEW' }
            if (-not (Test-Path -LiteralPath (Get-ServerFile $a[0]))) { Fail "no saved server called '$($a[0])'" }
            if (-not (Test-ValidName $a[1])) { Fail "'$($a[1])' cannot be a name: letters, digits, dot, dash and underscore only" }
            if (Test-Path -LiteralPath (Get-ServerFile $a[1])) { Fail "'$($a[1])' is already taken" }
            Move-Item -LiteralPath (Get-ServerFile $a[0]) -Destination (Get-ServerFile $a[1])
            if (Test-Path -LiteralPath (Get-UnitCacheFile $a[0])) {
                Move-Item -LiteralPath (Get-UnitCacheFile $a[0]) -Destination (Get-UnitCacheFile $a[1]) -Force -ErrorAction SilentlyContinue
            }
            $cur = Join-Path $script:ConfigDir 'current'
            if ((Test-Path -LiteralPath $cur) -and ((Get-Content -LiteralPath $cur -TotalCount 1) -eq $a[0])) { Set-Current $a[1] }
            Say "Renamed '$($a[0])' to '$($a[1])'."
        }
        { @('remove', 'rm', 'forget') -contains $_ } { Invoke-Logout $a }
        default { UsageFail "unknown servers command '$sub' -- list, use, rename or remove" }
    }
}

# ------------------------------------------------------------ diag and nerd

$script:Report = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$verdict, [string]$message) {
    $label = @{ ok = 'OK  '; warn = 'WARN'; fail = 'FAIL'; skip = 'skip' }[$verdict]
    Say "  $label $message"
    $script:Report.Add([ordered]@{ verdict = $verdict; message = $message })
}
function Write-Section([string]$title) { Say ''; Say "== $title ==" }
function Get-Count([string]$verdict) { return @($script:Report | Where-Object { $_.verdict -eq $verdict }).Count }

function Invoke-Diag {
    Use-Server
    Say "breezectl diag -> $($script:Server.Base) ($($script:Server.Name))"
    Invoke-DiagChecks
    Write-Section 'summary'
    Say "  $(Get-Count 'ok') ok, $(Get-Count 'warn') warning(s), $(Get-Count 'fail') failure(s)"
    if ((Get-Count 'fail') -gt 0) { Say '  result: PROBLEMS FOUND' }
    elseif ((Get-Count 'warn') -gt 0) { Say '  result: OK, with warnings' }
    else { Say '  result: OK' }
}

function Invoke-DiagChecks {
    Write-Section 'this machine'
    $os = [Environment]::OSVersion.VersionString
    if ($PSVersionTable.OS) { $os = $PSVersionTable.OS }
    Add-Check ok "breezectl.ps1 $script:Version, PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)), on $os"
    if ($script:OnWindows) {
        $d = [IO.File]::ReadAllText((Get-ServerFile $script:Server.Name)) | ConvertFrom-Json
        if (Get-Field $d 'device_token_dpapi') { Add-Check ok 'the saved key and token are encrypted for this Windows account' }
        else { Add-Check warn 'the saved login is not encrypted -- pair again to encrypt it: breezectl login' }
    } else {
        $mode = (& ls -ln (Get-ServerFile $script:Server.Name) 2>$null) -replace '^(\S{10}).*$', '$1'
        if ($mode -eq '-rw-------') { Add-Check ok 'the saved login is readable only by you' }
        else { Add-Check warn "the saved login is $mode -- run: chmod 600 $(Get-ServerFile $script:Server.Name)" }
    }

    Write-Section 'server'
    $r = Invoke-Api GET '/api/health'
    if ($r.Ok -and (Get-Field $r.Body 'status') -eq 'ok') { Add-Check ok "the server answers /api/health ($($r.Ms) ms)" }
    else {
        $why = $r.Error; if (-not $why) { $why = 'health did not say ok' }
        Add-Check fail "cannot reach the server: $why"; return
    }
    $features = @()
    $r = Invoke-Api GET '/api/version'
    if ($r.Ok) {
        $commit = Get-Field $r.Body 'commit'; if (-not $commit) { $commit = 'unknown' }
        Add-Check ok "version $(Get-Field $r.Body 'version') (commit $commit)"
        $features = @(As-List (Get-Field $r.Body 'features'))
        if ($features.Count -gt 0) { Add-Check ok "features: $($features -join ' ')" } else { Add-Check warn 'the server advertises no features' }
    } else { Add-Check fail "version failed: $($r.Error)" }

    Write-Section 'authentication'
    $r = Invoke-Api GET '/api/auth/whoami'
    if ($r.Ok) { Add-Check ok "this machine is paired as `"$(Get-Field $r.Body 'label')`" (auth v$(Get-Field $r.Body 'auth_version'), id $(Get-Field $r.Body 'token_id'))" }
    else { Add-Check fail "whoami failed: $(($r.Error -split "`n")[0])" }
    # A wrong key must be refused: a server that accepts anything would pass
    # every other check while being wide open.
    $r = Invoke-Api GET '/api/units' -Key 'obviously-not-the-key'
    if ($r.Ok) { Add-Check fail 'a wrong API key was ACCEPTED -- this server is not authenticating' }
    else { Add-Check ok 'a wrong API key is refused' }

    Write-Section 'units'
    $r = Invoke-Api GET '/api/units'
    if (-not $r.Ok) { Add-Check fail "cannot list units: $($r.Error)"; return }
    $units = @(As-List $r.Body)
    if ($units.Count -eq 0) { Add-Check warn 'no units are configured -- add one in the web panel'; return }
    Add-Check ok "$($units.Count) unit(s) configured"
    $r = Invoke-Api GET '/api/units/state'
    if ($r.Ok) {
        $states = @(As-List (Get-Field $r.Body 'states')); $errors = @(As-List (Get-Field $r.Body 'errors'))
        Add-Check ok "batch read: $($states.Count) answered, $($errors.Count) did not, in $($r.Ms) ms"
        if (($states.Count + $errors.Count) -ne $units.Count) { Add-Check fail "the batch covered $($states.Count + $errors.Count) of $($units.Count) units" }
        foreach ($e in $errors) { Add-Check warn "$(Get-Field $e 'name') did not answer: $(Get-Field $e 'error')" }
    } else { Add-Check fail "batch read failed: $($r.Error)" }

    foreach ($u in $units) {
        $id = Get-Field $u 'id'
        Write-Section "unit: $(Get-Field $u 'name') ($id)"
        $r = Invoke-Api GET "/api/units/$id/state"
        if (-not $r.Ok) { Add-Check warn "state read failed: $(($r.Error -split "`n")[0])"; continue }
        if ((Get-Field $r.Body 'online') -eq $false) { Add-Check warn 'the unit reports itself offline'; continue }
        Add-Check ok "state read in $($r.Ms) ms"
        if ($r.Ms -gt 1500) { Add-Check warn "$($r.Ms) ms is slow -- check the wireless signal to this unit" }
        Test-State $r.Body
        if ($features -contains 'unit_capabilities') {
            $c = Invoke-Api GET "/api/units/$id/capabilities"
            if ($c.Ok) {
                $modes = @(As-List (Get-Field $c.Body 'operational_modes')).Count
                if ($modes -eq 0) { Add-Check warn 'the unit reported no operating modes' }
                else { Add-Check ok "supports $modes mode(s), $(@(As-List (Get-Field $c.Body 'swing_modes')).Count) swing, $(@(As-List (Get-Field $c.Body 'fan_speeds')).Count) fan speed(s)" }
            } else { Add-Check warn "capabilities failed: $(($c.Error -split "`n")[0])" }
        }
    }

    Write-Section 'scheduling'
    if ($features -contains 'programs') {
        $r = Invoke-Api GET '/api/programs/status'
        if ($r.Ok) {
            $running = (Get-Field $r.Body 'running') -eq $true
            $v = 'fail'; $word = 'NOT running'; if ($running) { $v = 'ok'; $word = 'running' }
            Add-Check $v "scheduler $word ($(Get-Field $r.Body 'runs') run(s), $(Get-Field $r.Body 'errors') error(s), tick $(Get-Field $r.Body 'tick_seconds')s)"
        } else { Add-Check fail "scheduler status failed: $($r.Error)" }
        $r = Invoke-Api GET '/api/programs'
        if ($r.Ok) {
            $all = @(As-List $r.Body)
            Add-Check ok "$($all.Count) program(s), $(@($all | Where-Object { (Get-Field $_ 'enabled') -eq $true }).Count) enabled"
        } else { Add-Check warn "cannot list programs: $($r.Error)" }
    } else { Add-Check skip 'this server has no programs feature' }
    if ($features -contains 'sleep_timer') {
        $r = Invoke-Api GET '/api/timers?kind=all'
        if ($r.Ok) { Add-Check ok "$(@(As-List $r.Body).Count) timer(s) pending" } else { Add-Check warn "cannot list timers: $($r.Error)" }
    }

    Write-Section 'input validation'
    # A bad value must be refused before it reaches the firmware. Read-only by
    # construction: the server refuses it before any unit is asked anything.
    $r = Invoke-Api POST "/api/units/$(Get-Field $units[0] 'id')/control" ([ordered]@{ target_temperature = 99 })
    if ($r.Ok) { Add-Check fail 'an out-of-range temperature was ACCEPTED and sent to a unit' }
    else { Add-Check ok 'an out-of-range temperature is refused before it reaches a unit' }
}

function Test-State($state) {
    $mode = Get-Field $state 'operational_mode'
    if (-not $mode) { Add-Check fail 'no operational_mode in the state' }
    elseif (@('AUTO', 'COOL', 'DRY', 'HEAT', 'FAN_ONLY') -ccontains $mode) { Add-Check ok "mode $mode is a known value" }
    else { Add-Check fail "mode '$mode' is not one this API defines" }
    $swing = Get-Field $state 'swing_mode'
    if (-not $swing) { Add-Check fail 'no swing_mode in the state' }
    elseif (@('OFF', 'VERTICAL', 'HORIZONTAL', 'BOTH') -ccontains $swing) { Add-Check ok "swing $swing is a known value" }
    else { Add-Check fail "swing '$swing' is not one this API defines" }
    $t = Get-Field $state 'target_temperature'
    if ($null -eq $t) { Add-Check fail 'no target_temperature in the state' }
    elseif ($t -ge 16 -and $t -le 30) { Add-Check ok "target $(Format-Temperature $t) $script:Deg is in range" }
    else { Add-Check fail "target $t $script:Deg is outside the 16-30 the API allows" }
    foreach ($f in @('indoor_temperature', 'outdoor_temperature')) {
        $v = Get-Field $state $f
        if ($null -eq $v) { Add-Check skip "$f is not reported" }
        elseif ($v -ge -50 -and $v -le 80) { Add-Check ok "$f $(Format-Temperature $v) $script:Deg" }
        else { Add-Check warn "$f $v $script:Deg is not a real temperature -- the unit has no such sensor" }
    }
}

# The same shape as `breeze-core diag --nerd` writes. No keys or tokens, but the
# server's hostname, LAN addresses and paths: worth a look before posting.
function Invoke-Nerd([string[]]$a) {
    if ($a.Count -gt 1) { UsageFail 'usage: breezectl nerd [FILE]' }
    Invoke-Diag
    $version = (Invoke-Api GET '/api/version').Body
    $r = Invoke-Api GET '/api/system'
    $system = $null; $systemError = $null
    if ($r.Ok) { $system = $r.Body } else { $systemError = $r.Error }
    $hostName = Get-Field (Get-Field $system 'os') 'hostname'; if (-not $hostName) { $hostName = 'server' }
    $hostName = $hostName -replace '[^A-Za-z0-9-]', '_'
    $file = "breeze-core-nerd-$hostName-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
    if ($a.Count -eq 1) { $file = $a[0] }
    $doc = [ordered]@{
        breeze_core_nerd = 1
        generated_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        generated_by = "breezectl.ps1 $script:Version nerd"
        client = [ordered]@{ powershell = [string]$PSVersionTable.PSVersion; edition = [string]$PSVersionTable.PSEdition }
        base_url = $script:Server.Base
        round_trip_ms = $r.Ms
        version = $version
        system = $system
        system_error = $systemError
        checks = $script:Report.ToArray()
        summary = [ordered]@{ ok = (Get-Count 'ok'); warn = (Get-Count 'warn'); fail = (Get-Count 'fail'); skip = (Get-Count 'skip') }
    }
    $path = $file
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path (Get-Location).Path $path }
    [IO.File]::WriteAllText($path, ($doc | ConvertTo-Json -Depth 32) + "`n", (New-Object Text.UTF8Encoding($false)))
    if (-not $script:OnWindows) { & chmod 600 $path 2>$null }
    Write-Section 'nerd'
    Say "  saved to $file"
    Say "  It holds this server's hostname, LAN addresses and file paths, but no"
    Say '  keys or tokens. Look it over before posting it anywhere public.'
}

# --------------------------------------------------------------------- help

function Show-Usage {
    Say @"
breezectl $script:Version -- control Breeze Core from this terminal

usage:
  breezectl 'NAME' [TYPE] [TEMPERATURE] [FLAP] [FAN] [EXTRA] [TIMER]
  breezectl status ['NAME'...]
  breezectl units
  breezectl timers [list | off 'NAME' 30m | start 'NAME' 07:30 [tomorrow|DAYS] | cancel ID|'NAME'|all]
  breezectl login [URL] [--name NAME] [--label LABEL] [--ca FILE] [--key-stdin] [--yes]
  breezectl logout [NAME]
  breezectl servers [list | use NAME | rename OLD NEW | remove NAME]
  breezectl diag
  breezectl nerd [FILE]
  breezectl version

controlling a unit (the same words as breeze-core control on the server):
  NAME         a unit's name, case-insensitive, or a unique prefix, or its id
  TYPE         cool | heat | dry | auto | fan | on | off
  TEMPERATURE  16-30, in half degrees
  FLAP         both | horizontal | vertical | off
  FAN          silent | low | medium | high | max | auto
  EXTRA        turbo | eco | turbo+eco | no-turbo | no-eco
  TIMER        15m | 90min | 2h -- switches the unit off after that long

  'none' is valid in any position and leaves that setting alone. Every slot
  after NAME may be omitted. A unit named like a command: breezectl control 'status' off

examples:
  breezectl kitchen cool 25.5 both auto turbo 15m
  breezectl 'living room' heat 30 horizontal low eco
  breezectl kitchen off
  breezectl kitchen none none none none none 30m
  breezectl timers start bedroom 06:45 tomorrow

options, before the command:
  --server NAME   use that saved server instead of the default (or BREEZECTL_SERVER)

Saved logins live in $script:ServersDir$(if ($script:OnWindows) { ', encrypted for your Windows account' } else { ', readable only by you' }).
"@
}

# --------------------------------------------------------------------- main

function Invoke-Main([string[]]$argv) {
    $script:OptServer = $null; $script:OptYes = $false; $script:CaFile = $null
    $i = 0
    while ($i -lt $argv.Count) {
        if (@('--server', '-s') -contains $argv[$i]) {
            if ($i + 1 -ge $argv.Count) { UsageFail '--server needs a name' }
            $script:OptServer = $argv[$i + 1]; $i += 2
        } elseif ($argv[$i] -like '--server=*') { $script:OptServer = $argv[$i].Substring(9); $i++ }
        elseif ($argv[$i] -eq '--') { $i++; break }
        else { break }
    }
    $rest = @()
    if ($i -lt $argv.Count) { $rest = @($argv[$i..($argv.Count - 1)]) }
    if ($rest.Count -eq 0) {
        Show-Usage
        if ((Get-ServerNames).Count -eq 0) { Say ''; Say 'Start with: breezectl login' }
        return 0
    }
    $command = $rest[0]
    $args2 = @()
    if ($rest.Count -gt 1) { $args2 = @($rest[1..($rest.Count - 1)]) }
    # Case-sensitive, as the sh script's `case` is: a unit called 'Status' is
    # a unit, not the command.
    switch -CaseSensitive ($command) {
        { @('help', '--help', '-h') -ccontains $_ } { Show-Usage; return 0 }
        { @('version', '--version', '-V') -ccontains $_ } {
            Say "breezectl.ps1 $script:Version"
            if (Get-CurrentName) {
                Use-Server
                $r = Invoke-Api GET '/api/version'
                if ($r.Ok) { Say "server '$($script:Server.Name)': Breeze Core $(Get-Field $r.Body 'version') at $($script:Server.Base)" }
            }
            return 0
        }
        'control' { Invoke-Control $args2; return 0 }
        { @('status', 'st') -ccontains $_ } { Invoke-Status $args2; return 0 }
        { @('units', 'list') -ccontains $_ } { Invoke-Units; return 0 }
        { @('timers', 'timer') -ccontains $_ } { Invoke-Timers $args2; return 0 }
        { @('login', 'pair') -ccontains $_ } { Invoke-Login $args2; return 0 }
        { @('logout', 'unpair') -ccontains $_ } { Invoke-Logout $args2; return 0 }
        { @('servers', 'server') -ccontains $_ } { Invoke-Servers $args2; return 0 }
        { @('diag', 'doctor') -ccontains $_ } { Invoke-Diag; if ((Get-Count 'fail') -gt 0) { return 1 }; return 0 }
        'nerd' { Invoke-Nerd $args2; if ((Get-Count 'fail') -gt 0) { return 1 }; return 0 }
        '__complete' { Invoke-Complete $args2; return 0 }
        { $_ -like '-*' } { UsageFail "unknown option $command" }
        default { Invoke-Control $rest; return 0 }
    }
}

# Dot-sourced by the tests with BREEZECTL_LIB=1, which want the functions only.
if ($env:BREEZECTL_LIB -eq '1') { return }
try {
    $code = Invoke-Main ([string[]]$args)
    exit $code
} catch [BreezeError] {
    if ($_.Exception.Message) { [Console]::Error.WriteLine('breezectl: ' + $_.Exception.Message) }
    exit $_.Exception.Code
} catch {
    [Console]::Error.WriteLine('breezectl: ' + $_.Exception.Message)
    exit 1
} finally {
    if ($null -ne $script:Http) { $script:Http.Dispose() }
}
