# Tests for breezectl.ps1's own logic, with no server: the control words, unit
# matching and the sentences it prints -- the same cases as tests/run.sh, so
# the two clients cannot drift apart.
#
#   pwsh -NoProfile -File tests/run.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1
#
# ASCII only, as breezectl.ps1 is: Windows PowerShell 5.1 would read anything
# else as the ANSI code page.

$env:BREEZECTL_LIB = '1'
. (Join-Path $PSScriptRoot '..\breezectl.ps1')
$env:BREEZECTL_LIB = $null
$ErrorActionPreference = 'Continue'

$script:Pass = 0; $script:Failed = 0
function Eq([string]$name, $got, $want) {
    if ([string]$got -ceq [string]$want) { $script:Pass++ }
    else { $script:Failed++; Write-Host "FAIL: $name"; Write-Host "  got:  $got"; Write-Host "  want: $want" }
}
function Has([string]$name, $text, [string]$needle) {
    if (([string]$text).Contains($needle)) { $script:Pass++ }
    else { $script:Failed++; Write-Host "FAIL: $name"; Write-Host "  $text"; Write-Host "  does not contain: $needle" }
}
# What a call refused with: the message of its BreezeError, without the
# "see: breezectl help" line a usage error adds.
function Err([scriptblock]$block) {
    try { & $block | Out-Null; return 'NO ERROR' }
    catch [BreezeError] { return ($_.Exception.Message -split "`n")[0] }
}
function Json($object) { return ($object | ConvertTo-Json -Compress) }
function Body { return (Json (Read-ControlWords $args).Body) }

$deg = [string][char]0x00B0 + 'C'

# ------------------------------------------------------------ control words
$p = Read-ControlWords @('cool', '25.5', 'both', 'auto', 'turbo', '15m')
Eq 'spec example 1' "$($p.Body.operational_mode) $($p.Body.power_state) $($p.Body.target_temperature) $($p.Body.swing_mode) $($p.Body.fan_speed) $($p.Body.turbo) [$($p.Body.eco)] $($p.Timer)" 'COOL True 25.5 BOTH 102 True [] 15'
$p = Read-ControlWords @('heat', '30', 'horizontal', 'low', 'eco')
Eq 'spec example 2' "$($p.Body.operational_mode) $($p.Body.target_temperature) $($p.Body.swing_mode) $($p.Body.fan_speed) $($p.Body.eco) [$($p.Body.turbo)] [$($p.Timer)]" 'HEAT 30 HORIZONTAL 40 True [] []'
$p = Read-ControlWords @('dry', '26', 'vertical', 'high', '25m')
Eq 'spec example 3' "$($p.Body.operational_mode) $($p.Body.target_temperature) $($p.Body.swing_mode) $($p.Body.fan_speed) $($p.Timer) [$($p.Body.turbo)$($p.Body.eco)]" 'DRY 26 VERTICAL 80 25 []'
Eq 'none in every position sends nothing' (Body none none none none none) '{}'
Eq 'none in the middle' (Body cool none both none eco) '{"power_state":true,"operational_mode":"COOL","swing_mode":"BOTH","eco":true}'
$p = Read-ControlWords @('none', 'none', 'none', 'none', 'none', '30m')
Eq 'a timer alone' "[$(Json $p.Body)] $($p.Timer)" '[{}] 30'
Eq 'off is power and nothing else' (Body off) '{"power_state":false}'
Eq 'on alone' (Body on) '{"power_state":true}'
Eq 'case-insensitive' (Body COOL 25.5 BOTH AUTO TURBO 15M) (Body cool 25.5 both auto turbo 15m)
$p = Read-ControlWords @('cool', '15m')
Eq 'a timer anywhere' "$($p.Body.operational_mode) $($p.Timer)" 'COOL 15'
foreach ($w in @('15m:15', '90min:90', '2h:120', '45minutes:45', '08m:8')) {
    $a, $b = $w -split ':'
    Eq "timer $a" (Get-TimerMinutes $a) $b
}
foreach ($w in @('45', '25.5', 'cool', 'm')) {
    $m = Get-TimerMinutes $w
    Eq "not a timer: $w" $(if ($null -eq $m) { 'none' } else { $m }) 'none'
}
Eq 'two timers refused' (Err { Read-ControlWords @('cool', '15m', '30m') }) 'two timers were given'
foreach ($t in @('16', '25.5', '30', '24c', ('24' + [char]0x00B0))) {
    Eq "temperature $t" (Err { Read-ControlWords @('none', $t) }) 'NO ERROR'
}
Eq 'temperature 24c' (Read-ControlWords @('none', '24c')).Body.target_temperature 24
Eq 'below the range' (Err { Read-ControlWords @('none', '15.5') }) "15.5 is outside the 16-30 $deg the API accepts"
Eq 'above the range' (Err { Read-ControlWords @('none', '31') }) "31 is outside the 16-30 $deg the API accepts"
Eq 'not a half degree' (Err { Read-ControlWords @('none', '24.3') }) '24.3 is not a whole or half degree'
Eq 'not a temperature' (Err { Read-ControlWords @('none', 'warm') }) "'warm' is not a temperature"
foreach ($f in @('silent:20', 'low:40', 'medium:60', 'high:80', 'max:100', 'auto:102', '60:60', '60%:60')) {
    $a, $b = $f -split ':'
    Eq "fan $a" (Read-ControlWords @('none', 'none', 'none', $a)).Body.fan_speed $b
}
Eq 'fan 55 refused' (Err { Read-ControlWords @('none', 'none', 'none', '55') }) '55 is not one of the speeds the API accepts (20, 40, 60, 80, 100, 102)'
Has 'fan word refused' (Err { Read-ControlWords @('none', 'none', 'none', 'breezy') }) 'Use silent, low, medium, high, max, auto, none, or a percentage'
$p = Read-ControlWords @('cool', 'none', 'none', 'none', 'turbo+eco')
Eq 'both extras' "$($p.Body.turbo) $($p.Body.eco)" 'True True'
$p = Read-ControlWords @('cool', 'none', 'none', 'none', 'no-turbo')
Eq 'extra off' $p.Body.turbo 'False'
Has 'a bad mode names the good ones' (Err { Read-ControlWords @('freeze') }) 'Use cool, heat, dry, auto, fan, on, off or none'
Has 'a bad flap names the good ones' (Err { Read-ControlWords @('cool', '24', 'sideways') }) 'horizontal'
Has 'too many arguments' (Err { Read-ControlWords @('cool', '24', 'both', 'auto', 'eco', '15m', 'extra') }) 'too many arguments'
# The field order is the server CLI's, so the two send the same bytes.
Eq 'field order' (Body heat 22.5 both low eco) '{"power_state":true,"operational_mode":"HEAT","target_temperature":22.5,"swing_mode":"BOTH","fan_speed":40,"eco":true}'

# ------------------------------------------------------------- unit matching
$units = '[{"id":"1","name":"Kitchen"},{"id":"2","name":"Living Room"},{"id":"3","name":"Back Room"}]' | ConvertFrom-Json
function Res([string]$w) {
    try { $u = Resolve-Unit $units $w; return "$($u.id)|$($u.name)" }
    catch [BreezeError] { return $_.Exception.Message }
}
foreach ($s in @('Kitchen', 'kitchen', 'KITCHEN', 'kItChEn', '  kitchen  ')) { Eq "name '$s'" (Res $s) '1|Kitchen' }
Eq 'multi-word' (Res 'living room') '2|Living Room'
Eq 'prefix kit' (Res 'kit') '1|Kitchen'
Eq 'prefix liv' (Res 'liv') '2|Living Room'
Eq 'an id' (Res '3') '3|Back Room'
Has 'unknown lists units' (Res 'garaza') 'Known units: Kitchen, Living Room, Back Room'
$units = '[{"id":"1","name":"Room One"},{"id":"2","name":"Room Two"}]' | ConvertFrom-Json
Has 'ambiguous lists candidates' (Res 'room') "'room' is ambiguous -- it could be Room One or Room Two"
$units = '[{"id":"1","name":"Kitchen"}]' | ConvertFrom-Json
Eq 'a one-unit server' (Res 'kit') '1|Kitchen'
$units = '[]' | ConvertFrom-Json
Has 'no units' (Res 'x') 'this server has no units configured'
$cajna = [string][char]0x010C + 'ajna'
$units = ('[{"id":"7","name":"Dnevna ' + $cajna + '"}]') | ConvertFrom-Json
Eq 'a name beyond ASCII' (Res ('dnevna ' + [char]0x010D)) "7|Dnevna $cajna"

# ---------------------------------------------------------------- sentences
function St([string]$json) { return (Get-Description ($json | ConvertFrom-Json)) }
Eq 'off still says what it is set to' `
    (St '{"power_state":false,"operational_mode":"HEAT","target_temperature":29.5,"fan_speed":102,"indoor_temperature":26.5}') `
    "off, set to heat, 29.5 $deg, fan auto; indoor 26.5 $deg"
Has 'modes are words' (St '{"power_state":true,"operational_mode":"FAN_ONLY"}') 'fan only, '
Eq 'a running unit' `
    (St '{"power_state":true,"operational_mode":"COOL","target_temperature":25.5,"swing_mode":"BOTH","fan_speed":102,"eco":false,"turbo":true,"indoor_temperature":27.0}') `
    "cool, 25.5 $deg, swing both, fan auto, turbo, indoor 27.0 $deg"
Eq 'a missing reading is dashes' (St '{"power_state":true,"operational_mode":"AUTO"}') "auto, -- $deg, indoor -- $deg"
Eq 'a whole number reads as one decimal' (St '{"power_state":true,"operational_mode":"COOL","target_temperature":24,"indoor_temperature":21}') "cool, 24.0 $deg, indoor 21.0 $deg"
function Na([string]$json) { return (Get-NotApplied ($json | ConvertFrom-Json)) }
Eq 'refused flaps and eco while off and heating' `
    (Na '{"power_state":false,"operational_mode":"HEAT","not_applied":["swing_mode","eco"]}') `
    "the air conditioner didn't accept the flap change and eco; the unit refused it, not Breeze Core. Units only move their flaps while they are running. Many units offer eco only while cooling, not while heating."
Eq 'nothing refused says nothing' (Na '{"not_applied":[]}') ''
Eq 'an old server says nothing' (Na '{"power_state":true}') ''
Eq 'one refused' `
    (Na '{"power_state":true,"operational_mode":"HEAT","not_applied":["turbo"]}') `
    "the air conditioner didn't accept turbo; the unit refused it, not Breeze Core. Many units offer turbo only in some modes."
Eq 'three refused' `
    (Na '{"power_state":true,"operational_mode":"COOL","not_applied":["fan_speed","turbo","target_temperature"]}') `
    "the air conditioner didn't accept the fan speed, turbo and the temperature; the unit refused it, not Breeze Core. It does not take this in its current mode. Many units offer turbo only in some modes."

# ------------------------------------------------------------------- odds
Eq 'url: bare address' (ConvertTo-BaseUrl '192.168.1.10') 'http://192.168.1.10:8420'
Eq 'url: with port' (ConvertTo-BaseUrl '192.168.1.10:9000') 'http://192.168.1.10:9000'
Eq 'url: https kept' (ConvertTo-BaseUrl 'https://breeze.example.com/') 'https://breeze.example.com'
Eq 'url: name' (ConvertTo-BaseUrl 'breeze.lan') 'http://breeze.lan:8420'
foreach ($n in @('home', 'cottage-2', 'a.b_c')) { Eq "name $n" (Test-ValidName $n) 'True' }
foreach ($n in @('', '.hidden', 'a b', 'a/b', ('x' * 70))) { Eq "name '$n' refused" (Test-ValidName $n) 'False' }
Eq 'at phrase, soon' (Get-AtPhrase '2026-10-16T21:45:00' 1500) ', at 21:45'
Eq 'at phrase, far' (Get-AtPhrase '2026-10-17T07:30:00' 50000) ', at 07:30 on 2026-10-17'
# PowerShell 7 reads such a string as a [datetime]; the digits must survive.
$t = '{"fires_at":"2026-10-17T07:30:00"}' | ConvertFrom-Json
Eq 'at phrase from parsed JSON' (Get-AtPhrase $t.fires_at 50000) ', at 07:30 on 2026-10-17'
Eq 'remaining: seconds' (Format-Remaining 30) 'in under a minute'
Eq 'remaining: rounds up' (Format-Remaining 61) 'in 2 min'
Eq 'remaining: hours' (Format-Remaining 7200) 'in 2 h'
Eq 'remaining: days' (Format-Remaining 216000) 'in 2 days 12 h'
Eq 'list of none' (@(As-List $null)).Count 0
Eq 'list of one' (@(As-List ('[{"a":1}]' | ConvertFrom-Json))).Count 1
Eq 'list of an empty array' (@(As-List ('{"s":[]}' | ConvertFrom-Json).s)).Count 0

Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
