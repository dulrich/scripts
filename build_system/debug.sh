#!/bin/bash
for _a in "$@"; do case "$_a" in --help)
	printf 'usage: %s %s\n' "${0##*/}" '[program args]'
	printf '%s\n' 'Compile _build.c, build in debug mode, then run the program under gdb.'
	exit 0;; esac; done
# Generated copies carry no build-id helper; answer the flags only where it exists.
_bid="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../util/lib/build-id.sh"
# shellcheck source=util/lib/build-id.sh
[ -r "$_bid" ] && { . "$_bid"; build_flags "${BASH_SOURCE[0]}" "$@"; }
set -euo pipefail

declare -a gcc_flags
# Generated copies resolve their sibling flag fragment at runtime; the repo gate
# intentionally runs without ShellCheck's external-source mode.
# shellcheck source=build-flags.sh
# shellcheck disable=SC1091
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/build-flags.sh"

gcc "${gcc_flags[@]}" _build.c -lutil -o ._build -ggdb \
	&& ./._build -d \
	&& gdb -x ~/.gdbinit -ex=r --args __SED_TOKEN_EXE_PATH__SED_TOKEN_EXE_NAME "$@"
