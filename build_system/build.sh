#!/bin/bash
for _a in "$@"; do case "$_a" in --help|-h)
	printf 'usage: %s %s\n' "${0##*/}" '[build options: -d -p -r -c -v]'
	printf '%s\n' 'Compile the _build.c bootstrap, then run it with the given options to build the project.'
	exit 0;; esac; done
set -euo pipefail

declare -a gcc_flags
# Generated copies resolve their sibling flag fragment at runtime; the repo gate
# intentionally runs without ShellCheck's external-source mode.
# shellcheck source=build-flags.sh
# shellcheck disable=SC1091
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/build-flags.sh"

gcc "${gcc_flags[@]}" _build.c -lutil -o ._build -ggdb

# The tracked build system is an uninstantiated project template. Compiling it
# validates the bootstrap; mkproject replaces these tokens before generated
# copies execute the builder.
if grep -q '__SED_TOKEN_' _build.c; then
	exit 0
fi

./._build "$@"
