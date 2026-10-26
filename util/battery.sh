#!/usr/bin/env bash
# battery.sh: report battery charge, health and time estimate from sysfs.
# `util battery` prints one line per battery plus a total; `--brief` prints
# just the total for prompts and `ssh <host> …` checks. Reads only
# /sys/class/power_supply (override with BATTERY_SYSFS), so it needs no
# upower/acpi and works the same on every Linux host.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

usage() {
	printf 'usage: %s %s\n' "${0##*/}" '[--brief]'
	printf '%s\n' 'Print charge %, status, energy now/full, health (full vs design), power draw and'
	printf '%s\n' 'time to full/empty for each battery, plus a total and the AC adapter state.'
	printf '%s\n' '  --brief   one line: total %, charging/discharging state, time estimate'
	printf '%s\n' 'Reads BATTERY_SYSFS (default /sys/class/power_supply); exit 1 when no battery is found.'
}

brief=0
for arg in "$@"; do
	case "$arg" in
		--help|-h) usage; exit 0 ;;
		--brief) brief=1 ;;
		*) usage >&2; exit 2 ;;
	esac
done

set -uo pipefail

sysfs=${BATTERY_SYSFS:-/sys/class/power_supply}

# read_num <file>: integer content of a sysfs file, empty when absent/unreadable.
read_num() {
	local v
	[ -r "$1" ] || return 0
	read -r v < "$1" 2>/dev/null || return 0
	[[ $v =~ ^-?[0-9]+$ ]] && printf '%s' "${v#-}"
}

read_str() {
	local v=
	[ -r "$1" ] && read -r v < "$1" 2>/dev/null
	printf '%s' "$v"
}

# fixed2 <micro-units>: X.XX
fixed2() {
	printf '%d.%02d' $(( $1 / 1000000 )) $(( ($1 % 1000000) / 10000 ))
}

# pct1 <part> <whole>: XX.X
pct1() {
	local p=$(( $1 * 1000 / $2 ))
	printf '%d.%d' $(( p / 10 )) $(( p % 10 ))
}

# hm <now> <rate>: H:MM for now/rate hours, empty when rate is 0.
hm() {
	[ "$2" -gt 0 ] || return 0
	local m=$(( $1 * 60 / $2 ))
	printf '%d:%02d' $(( m / 60 )) $(( m % 60 ))
}

ac="unknown"
names=()
tot_now=0 tot_full=0 tot_rate=0 chg_need=0 unit_all="" mixed=0 any_chg=0 any_dis=0
lines=()

for dev in "$sysfs"/*; do
	[ -d "$dev" ] || [ -L "$dev" ] || continue
	type=$(read_str "$dev/type")
	name=${dev##*/}
	if [ "$type" = "Mains" ]; then
		case "$(read_str "$dev/online")" in
			1) ac="online" ;;
			0) [ "$ac" = "online" ] || ac="offline" ;;
		esac
		continue
	fi
	[ "$type" = "Battery" ] || continue
	# skip peripheral batteries (mice, headsets) that report scope=Device
	[ "$(read_str "$dev/scope")" = "Device" ] && continue

	if [ -n "$(read_num "$dev/energy_full")" ]; then
		unit=Wh rate_unit=W
		now=$(read_num "$dev/energy_now"); full=$(read_num "$dev/energy_full")
		design=$(read_num "$dev/energy_full_design"); rate=$(read_num "$dev/power_now")
	elif [ -n "$(read_num "$dev/charge_full")" ]; then
		unit=Ah rate_unit=A
		now=$(read_num "$dev/charge_now"); full=$(read_num "$dev/charge_full")
		design=$(read_num "$dev/charge_full_design"); rate=$(read_num "$dev/current_now")
	else
		unit="" now="" full="" design="" rate=""
	fi
	status=$(read_str "$dev/status"); status=${status:-Unknown}
	cap=$(read_num "$dev/capacity")
	if [ -z "$cap" ] && [ -n "$now" ] && [ "${full:-0}" -gt 0 ]; then
		cap=$(( now * 100 / full ))
	fi
	names+=("$name")

	line=$(printf '%-6s %4s  %-13s' "$name" "${cap:-?}%" "$status")
	if [ -n "$unit" ] && [ "${full:-0}" -gt 0 ]; then
		line+=$(printf '  %s/%s %s' "$(fixed2 "${now:-0}")" "$(fixed2 "$full")" "$unit")
		if [ "${design:-0}" -gt 0 ]; then
			line+="  health $(pct1 "$full" "$design")%"
		fi
		rate=${rate:-0}
		if [ "$rate" -gt 0 ]; then
			line+="  $(fixed2 "$rate") $rate_unit"
			case "$status" in
				Charging) line+="  ~$(hm $(( full - ${now:-0} )) "$rate") to full" ;;
				Discharging) line+="  ~$(hm "${now:-0}" "$rate") left" ;;
			esac
		fi
		if [ -z "$unit_all" ]; then unit_all=$unit; elif [ "$unit_all" != "$unit" ]; then mixed=1; fi
		tot_now=$(( tot_now + ${now:-0} )); tot_full=$(( tot_full + full ))
		case "$status" in
			Charging) any_chg=1; tot_rate=$(( tot_rate + rate )); chg_need=$(( chg_need + full - ${now:-0} )) ;;
			Discharging) any_dis=1; tot_rate=$(( tot_rate + rate )) ;;
		esac
	fi
	lines+=("$line")
done

if [ ${#names[@]} -eq 0 ]; then
	echo "no battery found under $sysfs" >&2
	exit 1
fi

if [ "$any_dis" -eq 1 ]; then state=discharging
elif [ "$any_chg" -eq 1 ]; then state=charging
else state=idle
fi

total="AC $ac"
eta=""
if [ "$mixed" -eq 0 ] && [ "$tot_full" -gt 0 ]; then
	total=$(printf '%s%%  %s  %s/%s %s  AC %s' "$(pct1 "$tot_now" "$tot_full")" "$state" \
		"$(fixed2 "$tot_now")" "$(fixed2 "$tot_full")" "$unit_all" "$ac")
	if [ "$state" = discharging ]; then
		eta=$(hm "$tot_now" "$tot_rate"); [ -n "$eta" ] && eta="~$eta left"
	elif [ "$state" = charging ]; then
		eta=$(hm "$chg_need" "$tot_rate"); [ -n "$eta" ] && eta="~$eta to full"
	fi
fi

if [ "$brief" -eq 1 ]; then
	printf '%s%s\n' "$total" "${eta:+  $eta}"
	exit 0
fi

printf '%s\n' "${lines[@]}"
printf '%-6s %s%s\n' total "$total" "${eta:+  $eta}"
