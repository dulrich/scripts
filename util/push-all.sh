#!/usr/bin/env bash
# push-all.sh: apply `cl`'s push semantics to every initiative-bearing repo
# directly under the code root. Bare = read-only status table; --push pushes
# (refused inside an agent session). Per-repo logic is util/lib/push.sh,
# shared with `cl`.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

# shellcheck source=util/lib/build-id.sh
case " $* " in *" --help "*|*" -h "*) ;; *) . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/build-id.sh"; build_flags "${BASH_SOURCE[0]}" "$@" ;; esac
usage() {
	printf 'usage: %s %s\n' "${0##*/}" '[--push] [--verbose] [--root <dir>] [--publish-mjs <file>]'
	printf '%s\n' 'Report (default, read-only) or push (--push) master of every git repo directly'
	printf '%s\n' 'under the code root that has a root INITIATIVE.md (or legacy DEVELOPMENT.md).'
	printf '%s\n' '  --push               push master to its upstream; mirror the github remote,'
	printf '%s\n' '                       rebuilding the projection only when it lags. Refused'
	printf '%s\n' '                       (exit 2, nothing pushed) when CLAUDECODE or CODEX_* is set'
	printf '%s\n' '  --verbose            also list in-sync and skipped repos (default: pending only)'
	printf '%s\n' '  --root <dir>         code root (default: code_path from config.sh, else ~/code)'
	printf '%s\n' '  --publish-mjs <file> publish.mjs path (default: publish_mjs from config.sh)'
	printf '%s\n' 'No fetch: counts use local tracking refs. A repo without a master upstream is'
	printf '%s\n' 'skipped. Exit 1 if any repo failed, 2 on usage error or refusal.'
}

set -uo pipefail

here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
code_path="$HOME/code"
publish_mjs=""
# shellcheck source=/dev/null
[ -f "$here/../config.sh" ] && . "$here/../config.sh"
# shellcheck source=util/lib/push.sh
. "$here/lib/push.sh"

push=0
verbose=0
root=
while [ $# -gt 0 ]; do
	case $1 in
		--help|-h) usage; exit 0 ;;
		--push) push=1 ;;
		--verbose|-v) verbose=1 ;;
		--root) [ $# -ge 2 ] || { usage >&2; exit 2; }; root=$2; shift ;;
		--publish-mjs) [ $# -ge 2 ] || { usage >&2; exit 2; }; publish_mjs=$2; shift ;;
		*) usage >&2; exit 2 ;;
	esac
	shift
done
root=${root:-$code_path}

if [ "$push" -eq 1 ] && { [ -n "${CLAUDECODE+x}" ] || [ -n "$(compgen -e CODEX_)" ]; }; then
	echo "push-all: --push refused inside an agent session (CLAUDECODE/CODEX_* set); run it yourself" >&2
	exit 2
fi
[ -d "$root" ] || { echo "push-all: no such root: $root" >&2; exit 2; }

# _pa_repo <push 0|1> <name>: run inside the repo. Prints the summary line.
# Returns 0 = in sync / pushed, 1 = failed, 2 = skipped, 3 = work pending (status).
_pa_repo () {
	local do_push=$1 name=$2 remote merge ahead=0 proj="" pending=0 top st lag ptip btip unp=no
	local rc=0 g tmp
	if ! git rev-parse --verify -q refs/heads/master > /dev/null; then
		[ "$verbose" -eq 1 ] && echo "$name: skipped (no master branch)"
		return 2
	fi
	remote=$(git config --get branch.master.remote)
	merge=$(git config --get branch.master.merge)
	if [ -z "$remote" ] || [ -z "$merge" ]; then
		[ "$verbose" -eq 1 ] && echo "$name: skipped (master has no upstream)"
		return 2
	fi
	if ! ahead=$(git rev-list --count 'master@{upstream}..master' 2> /dev/null); then
		[ "$verbose" -eq 1 ] && echo "$name: skipped (upstream ref for master missing locally)"
		return 2
	fi
	[ "$ahead" -gt 0 ] && pending=1
	top=$(git rev-parse --show-toplevel)
	if git remote get-url github > /dev/null 2>&1 && [ -f "$top/.publication.json" ]; then
		if [ -n "$publish_mjs" ] && [ -f "$publish_mjs" ]; then
			if st=$(bun "$publish_mjs" status --repo "$top" 2> /dev/null); then
				lag=$(_push_json_field "$st" lagCommits)
				ptip=$(_push_json_field "$st" publicTip)
				btip=$(_push_json_field "$st" publishedTip)
				[ "$ptip" != "$btip" ] && unp=yes
				proj="; projection lag ${lag:-?}, unpushed projection: $unp"
				{ _push_needs_projection "$st" || [ "$unp" = yes ]; } && pending=1
			else
				proj="; projection status unavailable"
			fi
		else
			proj="; projection n/a (publish_mjs unset)"
		fi
	fi
	if [ "$do_push" -eq 0 ]; then
		{ [ "$pending" -eq 1 ] || [ "$verbose" -eq 1 ]; } && echo "$name: origin +$ahead$proj"
		[ "$pending" -eq 1 ] && return 3
		return 0
	fi
	tmp=$(mktemp) || return 1
	# Project (and scan) before pushing anything: a failed scan pushes
	# nowhere, so the flagged commits stay local and can be amended.
	g=2
	{
		if git remote get-url github > /dev/null 2>&1; then
			_cl_github_push conditional master
			g=$?
		fi
		if [ "$g" -eq 1 ]; then
			rc=1
			echo "(not pushing to origin either; amend the flagged commits locally)"
		else
			_cl_origin_push master || rc=1
			if [ "$g" -eq 0 ]; then
				if git config --get remote.github.push > /dev/null 2>&1; then
					git push github || rc=1
				else
					git push github "$PUSH_GH_SRC:$PUSH_GH_DST" || rc=1
				fi
			fi
		fi
	} < /dev/null > "$tmp" 2>&1
	if [ "$rc" -ne 0 ]; then
		echo "$name: FAILED (origin +$ahead$proj)"
		sed 's/^/    /' "$tmp"
	elif [ "$pending" -eq 1 ] || [ "$verbose" -eq 1 ]; then
		echo "$name: pushed (origin +$ahead$proj)"
		sed 's/^/    /' "$tmp"
	fi
	rm -f "$tmp"
	return "$rc"
}

total=0 ok=0 failed=0 skipped=0 pending=0
for dir in "$root"/*/; do
	dir=${dir%/}
	[ -e "$dir/.git" ] || continue
	[ -f "$dir/INITIATIVE.md" ] || [ -f "$dir/DEVELOPMENT.md" ] || continue
	total=$((total + 1))
	( cd "$dir" && _pa_repo "$push" "${dir##*/}" )
	case $? in
		0) ok=$((ok + 1)) ;;
		2) skipped=$((skipped + 1)) ;;
		3) pending=$((pending + 1)) ;;
		*) failed=$((failed + 1)) ;;
	esac
done

printf '%d repos: %d in sync/pushed, %d pending, %d skipped, %d failed\n' \
	"$total" "$ok" "$pending" "$skipped" "$failed"
[ "$failed" -eq 0 ]
