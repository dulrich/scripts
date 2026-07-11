#!/bin/bash

# dispatch.sh: filesystem-router for util/ subcommands.
# `util <name> [args...]` execs util/<name>[.sh]. Adding a command is just
# dropping a new util/<name>.sh file (symlinked-in private scripts work too).
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

here=$( dirname $( realpath "${BASH_SOURCE[0]}" ) )

source "$here/lib.sh"

###

# infrastructure files that are not subcommands
_util_infra="dispatch lib completions"

_util_list() {
	local f name
	for f in "$here"/*.sh; do
		[ -e "$f" ] || continue
		name=$( basename "$f" .sh )
		case " $_util_infra " in
			*" $name "*) continue ;;
		esac
		echo "$name"
	done
}

script="${1:-}"

if [ -z "$script" ]; then
	echo "usage: util <command> [args...]"
	echo ""
	echo "commands:"
	_util_list | sed 's/^/  /'
	exit 1
fi

if [ -f "$here/$script" ]; then
	shift
	exec "$here/$script" "$@"
elif [ -f "$here/${script}.sh" ]; then
	shift
	exec "$here/${script}.sh" "$@"
else
	echo "Unknown util <$script>" >&2
	echo "run 'util' with no arguments to list commands" >&2
	exit 1
fi
