#!/bin/bash
for _a in "$@"; do case "$_a" in --help)
	printf 'usage: %s %s\n' "${0##*/}" '[program args]'
	printf '%s\n' 'Compile _build.c, build with profiling, run under gdb, then gprof into prof.out.'
	exit 0;; esac; done
set -euo pipefail

declare -a gcc_flags
# Generated copies resolve their sibling flag fragment at runtime; the repo gate
# intentionally runs without ShellCheck's external-source mode.
# shellcheck source=build-flags.sh
# shellcheck disable=SC1091
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/build-flags.sh"

gcc "${gcc_flags[@]}" _build.c -lutil -o ._build -ggdb \
	&& ./._build -pd \
	&& gdb -x ~/.gdbinit -ex=r --args __SED_TOKEN_EXE_PATH__SED_TOKEN_EXE_NAME "$@" \
	&& gprof __SED_TOKEN_EXE_PATH__SED_TOKEN_EXE_NAME gmon.out > prof.out \
	&& nano prof.out
	
