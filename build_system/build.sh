#!/bin/bash
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
