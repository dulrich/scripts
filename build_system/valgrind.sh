#!/bin/bash
set -euo pipefail

declare -a gcc_flags
# Generated copies resolve their sibling flag fragment at runtime; the repo gate
# intentionally runs without ShellCheck's external-source mode.
# shellcheck source=build-flags.sh
# shellcheck disable=SC1091
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/build-flags.sh"

gcc "${gcc_flags[@]}" _build.c -lutil -o ._build -ggdb \
	&& ./._build -d \
	&& ./valgrind __SED_TOKEN_EXE_PATH__SED_TOKEN_EXE_NAME "$@"
