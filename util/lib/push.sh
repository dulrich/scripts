# shellcheck shell=bash
# push.sh: per-repo push logic shared by `cl` (aliases.sh) and `util push-all`.
# Sourced helper, not routable (lives under util/lib/). Uses the caller's
# $publish_mjs (config.sh). Run inside the repo being pushed.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

# _push_json_field <json> <name>: top-level scalar of `publish.mjs status`
# (printed two-space indented), without quotes or comma; `null` stays null.
_push_json_field () {
	printf '%s\n' "$1" |
		sed -n "s/^  \"$2\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" |
		head -n 1
}

# _push_needs_projection <status-json>: pure. 0 = rebuild the projection
# (lagCommits > 0, or no projected source yet, or unreadable), 1 = current.
_push_needs_projection () {
	local lag proj
	proj=$(_push_json_field "$1" projectedSource)
	lag=$(_push_json_field "$1" lagCommits)
	case $proj in '' | null) return 0 ;; esac
	case $lag in '' | null | *[!0-9]*) return 0 ;; esac
	[ "$lag" -gt 0 ]
}

# _cl_origin_push [branch]: push to origin when ahead of the upstream.
# No argument = `cl` legacy: current branch, plain `git push`, an uncountable
# upstream reads as "nothing to push". With <branch> = push that local branch
# to its own configured upstream, whatever is checked out. Returns the push
# status (0 when nothing to push), 3 when <branch> has no upstream.
_cl_origin_push () {
	local branch=${1:-} unpushed remote merge
	if [ -z "$branch" ]; then
		if unpushed=$(git rev-list --count '@{upstream}..HEAD' 2> /dev/null) &&
			[ "$unpushed" -gt 0 ]; then
			echo "(pushing $unpushed refs to origin)"
			git push
			return
		fi
		echo "(nothing to push)"
		return 0
	fi
	remote=$(git config --get "branch.$branch.remote")
	merge=$(git config --get "branch.$branch.merge")
	if [ -z "$remote" ] || [ -z "$merge" ]; then
		echo "($branch has no upstream)"
		return 3
	fi
	unpushed=$(git rev-list --count "$branch@{upstream}..$branch" 2> /dev/null) || unpushed=0
	if [ "$unpushed" -gt 0 ]; then
		echo "(pushing $unpushed refs to origin)"
		git push "$remote" "$branch:${merge#refs/heads/}"
		return
	fi
	echo "(nothing to push)"
	return 0
}

# Mirror to the `github` remote: derive the source/dest refs, rebuild the
# projection when a publication manifest exists, then count what is unpushed.
# Prints the user-visible messages; returns 0 = push needed, 1 = projection
# failed (do not push), 2 = nothing to push. Sets PUSH_GH_SRC / PUSH_GH_DST.
#   $1 mode: unconditional (default, `cl`: always project) | conditional
#      (project only when `publish.mjs status` reports lag or no projection)
#   $2 branch used as source and destination when no remote.github.push
#      mapping exists (default: HEAD / the current branch)
_cl_github_push () {
	local mode=${1:-unconditional} defsrc=${2:-} ghspec ghpush top pub st
	PUSH_GH_SRC=
	PUSH_GH_DST=

	if ghspec=$(git config --get remote.github.push 2> /dev/null); then
		ghspec=${ghspec#+}
		PUSH_GH_SRC=${ghspec%%:*}
		PUSH_GH_DST=${ghspec#*:}
		PUSH_GH_SRC=${PUSH_GH_SRC#refs/heads/}
		PUSH_GH_DST=${PUSH_GH_DST#refs/heads/}
		# A publication manifest means the projection must be rebuilt
		# (and scanned) from the current private master first; a failed
		# projection/scan stops the github push. Set publish_mjs in config.sh.
		top=$(git rev-parse --show-toplevel 2> /dev/null)
		if [ -n "$top" ] && [ -f "$top/.publication.json" ]; then
			pub=${publish_mjs:-}
			if [ -n "$pub" ] && [ -f "$pub" ]; then
				if [ "$mode" = conditional ]; then
					if ! st=$(bun "$pub" status --repo "$top"); then
						echo "(projection status failed; not pushing to github)"
						return 1
					fi
					if ! _push_needs_projection "$st"; then
						echo "(projection current)"
					fi
				fi
				if [ "$mode" != conditional ] || _push_needs_projection "$st"; then
					echo "(projecting $PUSH_GH_SRC)"
					if ! bun "$pub" project --repo "$top"; then
						echo "(projection failed; not pushing to github)"
						return 1
					fi
				fi
			else
				echo "(publish_mjs unset or missing; pushing the existing projection)"
			fi
		fi
	else
		PUSH_GH_SRC=${defsrc:-HEAD}
		PUSH_GH_DST=${defsrc:-$(git rev-parse --abbrev-ref HEAD)}
	fi
	ghpush=$(git rev-list --count "github/$PUSH_GH_DST..$PUSH_GH_SRC" 2> /dev/null)
	if [ -z "$ghpush" ] || [ "$ghpush" -gt 0 ]; then
		echo "(pushing ${ghpush:-all} refs to github)"
		return 0
	fi
	echo "(nothing to push to github)"
	return 2
}
