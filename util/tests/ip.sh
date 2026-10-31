#!/usr/bin/env bash
# ip.sh smoke: a stub `ip` (IP_CMD) feeds fixed output, no host network needed.

set -u

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$test_dir/../ip.sh"
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

absent() {
	local description=$1 unexpected=$2 actual=$3
	if [[ "$actual" != *"$unexpected"* ]]; then
		check "$description" "" ""
	else
		check "$description" "(no $unexpected)" "$actual"
	fi
}

cat > "$root/ip" <<'STUB'
#!/usr/bin/env bash
case "$*" in
	"-4 route show default") echo "default via 192.168.0.1 dev enp10s0 proto dhcp" ;;
	"-6 route show default") echo "default via fe80::1 dev wlp9s0 proto ra" ;;
	"-o addr show scope global")
		cat <<'OUT'
2: enp10s0    inet 192.168.0.3/24 brd 192.168.0.255 scope global dynamic enp10s0\       valid_lft 80000sec preferred_lft 80000sec
3: wlp9s0    inet6 2001:db8::5/64 scope global dynamic mngtmpaddr \       valid_lft 80000sec preferred_lft 80000sec
3: wlp9s0    inet6 2001:db8::abcd/64 scope global temporary dynamic \       valid_lft 80000sec preferred_lft 80000sec
3: wlp9s0    inet6 2001:db8::dead/64 scope global temporary deprecated dynamic \       valid_lft 80000sec preferred_lft 0sec
4: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\       valid_lft forever preferred_lft forever
5: br-aef8f026aa73    inet 172.22.0.1/16 brd 172.22.255.255 scope global br-aef8f026aa73\       valid_lft forever preferred_lft forever
6: wg0    inet 10.77.0.3/24 scope global wg0\       valid_lft forever preferred_lft forever
OUT
		;;
esac
STUB
chmod +x "$root/ip"
export IP_CMD="$root/ip"

out=$(bash "$script")
check "default-route iface marked" "enp10s0  192.168.0.3/24" "$out"
check "default marker" "default" "$(grep enp10s0 <<<"$out")"
check "vpn kept" "wg0" "$out"
check "global v6 kept, default on v6 route" "2001:db8::5/64" "$out"
check "temporary v6 labelled" "temporary" "$(grep abcd <<<"$out")"
absent "deprecated v6 hidden" "dead" "$out"
absent "docker hidden" "docker0" "$out"
absent "compose bridge hidden" "br-aef" "$out"

out=$(bash "$script" --all)
check "--all shows docker" "docker0" "$out"
check "--all shows bridge" "172.22.0.1/16" "$out"

out=$(bash "$script" -4)
absent "-4 hides v6" "2001:" "$out"
check "-4 keeps v4" "10.77.0.3/24" "$out"
out=$(bash "$script" -6)
absent "-6 hides v4" "192.168" "$out"

help=$(bash "$script" --help); rc=$?
check "--help exit 0" "0" "$rc"
check "--help usage" "usage:" "$help"
bash "$script" --bogus >/dev/null 2>&1; rc=$?
check "bad arg exit 2" "2" "$rc"

IP_CMD="$root/nope" bash "$script" >/dev/null 2>&1; rc=$?
check "missing ip exit 1" "1" "$rc"

printf '%d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
