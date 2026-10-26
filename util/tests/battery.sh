#!/usr/bin/env bash
# battery.sh smoke: fixture sysfs trees, no host battery needed.

set -u

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$test_dir/../battery.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

pass_count=0
fail_count=0

check() {
	local description=$1 expected=$2 actual=$3
	if [[ "$actual" == *"$expected"* ]]; then
		printf 'ok %d - %s\n' "$((pass_count + fail_count + 1))" "$description"
		pass_count=$((pass_count + 1))
	else
		printf 'not ok %d - %s\n  expected substring: %q\n  actual: %q\n' \
			"$((pass_count + fail_count + 1))" "$description" "$expected" "$actual" >&2
		fail_count=$((fail_count + 1))
	fi
}

# dev <tree> <name> key=value...
dev() {
	local d="$root/$1/$2" kv
	mkdir -p "$d"
	shift 2
	for kv in "$@"; do printf '%s\n' "${kv#*=}" > "$d/${kv%%=*}"; done
}

# two ThinkPad-style batteries (energy_* units), one charging, on AC
dev two AC type=Mains online=1
dev two BAT0 type=Battery status='Not charging' capacity=97 energy_now=16650000 energy_full=17130000 energy_full_design=23200000 power_now=0
dev two BAT1 type=Battery status=Charging capacity=94 energy_now=9090000 energy_full=9620000 energy_full_design=23480000 power_now=2310000
out=$(BATTERY_SYSFS="$root/two" bash "$script")
check 'per-battery health' 'health 73.8%' "$out"
check 'charging battery eta' '~0:13 to full' "$out"
check 'total ignores the idle battery gap' 'AC online  ~0:13 to full' "$out"
check 'total percent' 'total  96.2%  charging  25.74/26.75 Wh' "$out"
out=$(BATTERY_SYSFS="$root/two" bash "$script" --brief)
check 'brief is the total line' '96.2%  charging  25.74/26.75 Wh  AC online  ~0:13 to full' "$out"

# one discharging battery in charge_* units, a peripheral battery to skip
dev dis ADP1 type=Mains online=0
dev dis BAT0 type=Battery status=Discharging charge_now=2000000 charge_full=4000000 charge_full_design=5000000 current_now=1000000
dev dis hidpp_battery_0 type=Battery scope=Device status=Discharging capacity=10
out=$(BATTERY_SYSFS="$root/dis" bash "$script")
check 'computed capacity when the file is absent' 'BAT0    50%' "$out"
check 'charge units and time left' '2.00/4.00 Ah  health 80.0%  1.00 A  ~2:00 left' "$out"
check 'AC offline' 'AC offline' "$out"
if [[ "$out" == *hidpp* ]]; then seen=present; else seen=absent; fi
check 'peripheral battery skipped' 'absent' "$seen"

mkdir -p "$root/none"
BATTERY_SYSFS="$root/none" bash "$script" >/dev/null 2>&1
check 'no battery exits 1' '1' "$?"

bash "$script" --bogus >/dev/null 2>&1
check 'unknown argument exits 2' '2' "$?"

printf '%d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
