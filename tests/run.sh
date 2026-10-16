#!/bin/sh
# Tests for breezectl's own logic, with no server: the JSON reader, the
# control words, unit matching and the sentences it prints.
#
#   sh tests/run.sh            (or dash, busybox sh, ksh, bash ...)
#
# The control cases are breeze-core's own (crates/breeze-core/src/cli/
# control.rs), so the two clients cannot drift apart: a script written for
# `breeze-core control` must mean the same to breezectl.

here=$(cd "$(dirname "$0")" && pwd)
# Both are read by the sourced script.
# shellcheck disable=SC2034
BREEZECTL_LIB=1
# shellcheck source=../breezectl
. "$here/../breezectl"
# shellcheck disable=SC2034
LANG=C.UTF-8 DEG='°C'

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*"; }
eq() { # NAME GOT WANT
  if [ "$2" = "$3" ]; then ok; else bad "$1"; printf '  got:  %s\n  want: %s\n' "$2" "$3"; fi
}
has() { # NAME TEXT NEEDLE
  case "$2" in *"$3"*) ok ;; *) bad "$1"; printf '  %s\n  does not contain: %s\n' "$2" "$3" ;; esac
}

flat() { printf '%s' "$1" >"$TMPD/t.json"; jflat "$TMPD/t.json" || echo JSON-REJECTED; }
get() { jget "$TMPD/t.json.flat" "$1"; }

# ------------------------------------------------------------- the JSON reader
flat '{"a": 1, "b": "two", "c": [true, false, null], "d": {"e": -2.5e3}}'
eq "number" "$(get .a)" 1
eq "string" "$(get .b)" two
eq "array length" "$(get .c)" 3
eq "true" "$(get .c.0)" true
eq "null is typed" "$(jtype "$TMPD/t.json.flat" .c.2)" z
eq "nested exponent" "$(get .d.e)" -2.5e3
eq "missing is non-zero" "$(get .nope >/dev/null; echo $?)" 1

flat '{"name": "Back \"Room\" \\ 1", "u": "Čajna °C", "pair": "🌬", "nl": "a\nb\tc"}'
eq "escaped quotes and backslash" "$(get .name)" 'Back "Room" \ 1'
eq "unicode escape to UTF-8" "$(get .u)" "Čajna °C"
eq "surrogate pair" "$(get .pair)" "🌬"
eq "newline and tab become spaces" "$(get .nl)" "a b c"
flat '{"raw": "Dnevna Čajna"}'
eq "raw UTF-8 passes through" "$(get .raw)" "Dnevna Čajna"
flat '[]'
eq "empty array" "$(get .)" 0
flat '{"states":[],"errors":[]}'
eq "empty envelope" "$(get .states)$(get .errors)" 00
flat '
  [ { "id" : "1" ,
      "name" : "Kitchen" } ]
'
eq "whitespace and newlines" "$(get .0.name)" Kitchen
eq "not JSON is refused" "$(flat '<html>502 Bad Gateway</html>')" JSON-REJECTED
eq "truncated JSON is refused" "$(flat '{"a": [1, 2')" JSON-REJECTED
eq "trailing junk is refused" "$(flat '{"a": 1} x')" JSON-REJECTED
eq "json_str escapes" "$(json_str 'say "hi" \ now')" '"say \"hi\" \\ now"'

# ------------------------------------------------------------ control words
p() { parse_control "$@"; }
body_of() { p "$@" && control_body; }

p cool 25.5 both auto turbo 15m
eq "spec example 1" "$C_MODE $C_POWER $C_TEMP $C_SWING $C_FAN $C_TURBO [$C_ECO] $C_TIMER" "COOL true 25.5 BOTH 102 true [] 15"
p heat 30 horizontal low eco
eq "spec example 2" "$C_MODE $C_TEMP $C_SWING $C_FAN $C_ECO [$C_TURBO] [$C_TIMER]" "HEAT 30 HORIZONTAL 40 true [] []"
p dry 26 vertical high 25m
eq "spec example 3" "$C_MODE $C_TEMP $C_SWING $C_FAN $C_TIMER [$C_TURBO$C_ECO]" "DRY 26 VERTICAL 80 25 []"
eq "none in every position sends nothing" "$(body_of none none none none none)" "{}"
eq "none in the middle" "$(body_of cool none both none eco)" '{"power_state": true, "operational_mode": "COOL", "swing_mode": "BOTH", "eco": true}'
p none none none none none 30m
eq "a timer alone" "[$(control_body)] $C_TIMER" "[{}] 30"
eq "off is power and nothing else" "$(body_of off)" '{"power_state": false}'
eq "on alone" "$(body_of on)" '{"power_state": true}'
eq "case-insensitive" "$(body_of COOL 25.5 BOTH AUTO TURBO 15M)" "$(body_of cool 25.5 both auto turbo 15m)"
p cool 15m
eq "a timer anywhere" "$C_MODE $C_TIMER" "COOL 15"
for w in 15m:15 90min:90 2h:120 45minutes:45 08m:8; do
  eq "timer ${w%%:*}" "$(timer_minutes "${w%%:*}")" "${w#*:}"
done
for w in 45 25.5 cool m; do
  eq "not a timer: $w" "$(timer_minutes "$w" || echo none)" none
done
eq "two timers refused" "$(p cool 15m 30m || echo "$PARSE_ERROR")" "two timers were given"
for t in 16 25.5 30 24c 24°; do p none "$t" || bad "temperature $t refused"; done
eq "temperature 24c" "$(p none 24c; echo "$C_TEMP")" 24
eq "below the range" "$(p none 15.5 || echo "$PARSE_ERROR")" "15.5 is outside the 16-30 °C the API accepts"
eq "above the range" "$(p none 31 || echo "$PARSE_ERROR")" "31 is outside the 16-30 °C the API accepts"
eq "not a half degree" "$(p none 24.3 || echo "$PARSE_ERROR")" "24.3 is not a whole or half degree"
eq "not a temperature" "$(p none warm || echo "$PARSE_ERROR")" "'warm' is not a temperature"
for f in silent:20 low:40 medium:60 high:80 max:100 auto:102 60:60 60%:60; do
  p none none none "${f%%:*}"; eq "fan ${f%%:*}" "$C_FAN" "${f#*:}"
done
eq "fan 55 refused" "$(p none none none 55 || echo "$PARSE_ERROR")" "55 is not one of the speeds the API accepts (20, 40, 60, 80, 100, 102)"
has "fan word refused" "$(p none none none breezy || echo "$PARSE_ERROR")" "Use silent, low, medium, high, max, auto, none, or a percentage"
p cool none none none turbo+eco
eq "both extras" "$C_TURBO $C_ECO" "true true"
p cool none none none no-turbo
eq "extra off" "$C_TURBO" false
has "a bad mode names the good ones" "$(p freeze || echo "$PARSE_ERROR")" "Use cool, heat, dry, auto, fan, on, off or none"
has "a bad flap names the good ones" "$(p cool 24 sideways || echo "$PARSE_ERROR")" "horizontal"
has "too many arguments" "$(p cool 24 both auto eco 15m extra || echo "$PARSE_ERROR")" "too many arguments"

# ------------------------------------------------------------- unit matching
printf '%s' '[{"id":"1","name":"Kitchen"},{"id":"2","name":"Living Room"},{"id":"3","name":"Back Room"}]' >"$TMPD/u.json"
jflat "$TMPD/u.json"
res() { (resolve_unit "$TMPD/u.json.flat" "$1" && printf '%s|%s' "$UNIT_ID" "$UNIT_NAME") 2>&1; }
for s in Kitchen kitchen KITCHEN kItChEn "  kitchen  "; do eq "name '$s'" "$(res "$s")" "1|Kitchen"; done
eq "multi-word" "$(res 'living room')" "2|Living Room"
eq "prefix kit" "$(res kit)" "1|Kitchen"
eq "prefix liv" "$(res liv)" "2|Living Room"
eq "an id" "$(res 3)" "3|Back Room"
has "unknown lists units" "$(res garaza)" "Known units: Kitchen, Living Room, Back Room"
printf '%s' '[{"id":"1","name":"Room One"},{"id":"2","name":"Room Two"}]' >"$TMPD/a.json"
jflat "$TMPD/a.json"
has "ambiguous lists candidates" "$( (resolve_unit "$TMPD/a.json.flat" room) 2>&1)" "'room' is ambiguous -- it could be Room One or Room Two"
printf '%s' '[]' >"$TMPD/e.json"; jflat "$TMPD/e.json"
has "no units" "$( (resolve_unit "$TMPD/e.json.flat" x) 2>&1)" "this server has no units configured"

# ---------------------------------------------------------------- sentences
st() { printf '%s' "$1" >"$TMPD/s.json"; jflat "$TMPD/s.json"; describe "$TMPD/s.json.flat" ""; }
eq "off still says what it is set to" \
  "$(st '{"power_state":false,"operational_mode":"HEAT","target_temperature":29.5,"fan_speed":102,"indoor_temperature":26.5}')" \
  "off, set to heat, 29.5 °C, fan auto; indoor 26.5 °C"
has "modes are words" "$(st '{"power_state":true,"operational_mode":"FAN_ONLY"}')" "fan only, "
eq "a running unit" \
  "$(st '{"power_state":true,"operational_mode":"COOL","target_temperature":25.5,"swing_mode":"BOTH","fan_speed":102,"eco":false,"turbo":true,"indoor_temperature":27.0}')" \
  "cool, 25.5 °C, swing both, fan auto, turbo, indoor 27.0 °C"
eq "a missing reading is dashes" "$(st '{"power_state":true,"operational_mode":"AUTO"}')" "auto, -- °C, indoor -- °C"
na() { printf '%s' "$1" >"$TMPD/n.json"; jflat "$TMPD/n.json"; not_applied "$TMPD/n.json.flat" ""; }
eq "refused flaps and eco while off and heating" \
  "$(na '{"power_state":false,"operational_mode":"HEAT","not_applied":["swing_mode","eco"]}')" \
  "the air conditioner didn't accept the flap change and eco; the unit refused it, not Breeze Core. Units only move their flaps while they are running. Many units offer eco only while cooling, not while heating."
eq "nothing refused says nothing" "$(na '{"not_applied":[]}')" ""
eq "an old server says nothing" "$(na '{"power_state":true}')" ""
eq "three refused" \
  "$(na '{"power_state":true,"operational_mode":"COOL","not_applied":["fan_speed","turbo","target_temperature"]}')" \
  "the air conditioner didn't accept the fan speed, turbo and the temperature; the unit refused it, not Breeze Core. It does not take this in its current mode. Many units offer turbo only in some modes."

# ------------------------------------------------------------------- odds
eq "url: bare address" "$(normalise_url 192.168.1.10)" "http://192.168.1.10:8420"
eq "url: with port" "$(normalise_url 192.168.1.10:9000)" "http://192.168.1.10:9000"
eq "url: https kept" "$(normalise_url https://breeze.example.com/)" "https://breeze.example.com"
eq "url: name" "$(normalise_url breeze.lan)" "http://breeze.lan:8420"
for n in home cottage-2 a.b_c; do valid_name "$n" || bad "name $n refused"; done
for n in '' .hidden 'a b' 'a/b' "$(printf 'x%.0s' $(seq 1 70))"; do
  if valid_name "$n"; then bad "name '$n' accepted"; else ok; fi
done
eq "at phrase, soon" "$(at_phrase 2026-10-16T21:45:00 1500)" ", at 21:45"
eq "at phrase, far" "$(at_phrase 2026-10-17T07:30:00 50000)" ", at 07:30 on 2026-10-17"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
