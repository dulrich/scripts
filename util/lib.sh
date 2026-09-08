#!/bin/bash

# lib.sh: shared discovery helper for the util/ router and its completion.
# Sourced by both dispatch.sh (exec'd as a separate process) and
# completions.sh (sourced into the interactive shell), so this file must have
# no side effects when sourced -- no top-level exec, exit, or complete.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

# infrastructure files that are not subcommands
_util_infra="dispatch lib completions"

# _util_commands <dir>: list routable command names findable in <dir> --
# public util/*.sh (excluding infrastructure), then any private overlay
# (<dir>/../private/util/*.sh). The one discovery operation shared by
# dispatch.sh's listing and completions.sh's completion, so both stay in
# sync on overlay precedence, infrastructure exclusion, and .sh resolution.
_util_commands () {
	local dir=$1 priv f name
	priv="$dir/../private/util"

	for f in "$dir"/*.sh; do
		[ -e "$f" ] || continue
		name=$( basename "$f" .sh )
		case " $_util_infra " in
			*" $name "*) continue ;;
		esac
		echo "$name"
	done

	if [ -d "$priv" ]; then
		for f in "$priv"/*.sh; do
			[ -e "$f" ] || continue
			basename "$f" .sh
		done
	fi
}
