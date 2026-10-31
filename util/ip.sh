#!/usr/bin/env bash
# ip.sh: show the machine's useful IP addresses — the ones you'd hand to
# someone or ssh to — hiding loopback, link-local and container/VM plumbing
# (docker*, br-*, veth*, virbr*, …). The interface carrying the default route
# is marked. `--all` keeps the plumbing; `--public` also asks an external
# service for the public address (the only mode that touches the network).
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

# shellcheck source=util/lib/build-id.sh
case " $* " in *" --help "*|*" -h "*) ;; *) . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/build-id.sh"; build_flags "${BASH_SOURCE[0]}" "$@" ;; esac
usage() {
	printf 'usage: %s %s\n' "${0##*/}" '[--all] [--public] [-4|-6]'
	printf '%s\n' 'Print the real IP addresses of this machine, one per line: interface, address/prefix,'
	printf '%s\n' 'and "default" on the interface that carries the default route. Loopback, link-local'
	printf '%s\n' 'and container/VM interfaces (docker*, br-*, veth*, virbr*, vnet*, cni*, flannel*,'
	printf '%s\n' 'cali*, lxcbr*, lxdbr*, podman*) are hidden.'
	printf '%s\n' '  --all      also show container/VM interfaces'
	printf '%s\n' '  --public   also print the public address (queries IP_PUBLIC_URL via curl,'
	printf '%s\n' '             default https://ifconfig.me)'
	printf '%s\n' '  -4 / -6    IPv4 or IPv6 only'
}

all=0 public=0 fam=
for arg in "$@"; do
	case "$arg" in
		--help|-h) usage; exit 0 ;;
		--all) all=1 ;;
		--public) public=1 ;;
		-4) fam=inet ;;
		-6) fam=inet6 ;;
		*) usage >&2; exit 2 ;;
	esac
done

set -uo pipefail

ip_cmd=${IP_CMD:-ip}
if ! command -v "$ip_cmd" >/dev/null 2>&1; then
	printf 'ip: no %s on host (iproute2)\n' "$ip_cmd" >&2
	exit 1
fi

# Interfaces carrying a default route, v4 and v6.
default_ifs=" $( { "$ip_cmd" -4 route show default; "$ip_cmd" -6 route show default; } 2>/dev/null \
	| awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}' | tr '\n' ' ')"

virtual() {
	case "$1" in
		docker*|br-*|veth*|virbr*|vnet*|cni*|flannel*|cali*|lxcbr*|lxdbr*|podman*) return 0 ;;
	esac
	return 1
}

rows=()
w=0 aw=0
# `ip -o addr show scope global`: "N: IFACE FAMILY ADDR/PREFIX ... [temporary|deprecated] ..."
while read -r _ ifname family addr rest; do
	ifname=${ifname%%@*}
	[ -n "$fam" ] && [ "$family" != "$fam" ] && continue
	[ "$all" -eq 0 ] && virtual "$ifname" && continue
	case " $rest " in *" deprecated "*) continue ;; esac
	note=
	case "$default_ifs" in *" $ifname "*) note=default ;; esac
	case " $rest " in *" temporary "*) note="${note:+$note,}temporary" ;; esac
	rows+=("$ifname"$'\t'"$addr"$'\t'"$note")
	[ "${#ifname}" -gt "$w" ] && w=${#ifname}
	[ "${#addr}" -gt "$aw" ] && aw=${#addr}
done < <("$ip_cmd" -o addr show scope global 2>/dev/null)

for row in "${rows[@]}"; do
	IFS=$'\t' read -r ifname addr note <<<"$row"
	if [ -n "$note" ]; then
		printf '%-*s  %-*s  %s\n' "$w" "$ifname" "$aw" "$addr" "$note"
	else
		printf '%-*s  %s\n' "$w" "$ifname" "$addr"
	fi
done

if [ "$public" -eq 1 ]; then
	if ! command -v curl >/dev/null 2>&1; then
		printf 'public: no curl on host\n' >&2
		exit 1
	fi
	curl_fam=()
	[ "$fam" = inet ] && curl_fam=(-4)
	[ "$fam" = inet6 ] && curl_fam=(-6)
	if pub=$(curl -fsS --max-time 5 "${curl_fam[@]}" "${IP_PUBLIC_URL:-https://ifconfig.me}" 2>/dev/null) && [ -n "$pub" ]; then
		printf '%-*s  %s\n' "$w" public "$pub"
	else
		printf 'public: lookup failed\n' >&2
		exit 1
	fi
fi

[ "${#rows[@]}" -gt 0 ] || [ "$public" -eq 1 ] || { printf 'ip: no global addresses\n' >&2; exit 1; }
