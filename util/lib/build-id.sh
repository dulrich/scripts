# shellcheck shell=bash
# build-id.sh — fleet build-id helper (plans/fleet-build-version-gate.md, Decision 3).
# Sourceable copy-in template; bash + coreutils + git only.
#
#   . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/build-id.sh"
#   case " $* " in *" --help "*|*" -h "*) usage; exit 0 ;; esac   # --help wins
#   build_flags "${BASH_SOURCE[0]}" "$@"                          # exits 0 on --build/--version
#
# build_id <path>         print the tool-scoped build id of <path> (or `unknown`)
# build_flags <path> ...  if the args contain --build or --version, print the id and exit 0

build_id() {
  local real dir top tool d sha st
  real=$(readlink -f -- "$1" 2>/dev/null) || { echo unknown; return 0; }
  [ -e "$real" ] || { echo unknown; return 0; }
  if [ -d "$real" ]; then dir=$real; else dir=$(dirname -- "$real"); fi
  top=$(cd -- "$dir" && git --no-optional-locks rev-parse --show-toplevel 2>/dev/null) || { echo unknown; return 0; }
  [ -n "$top" ] || { echo unknown; return 0; }
  tool=$top
  d=$dir
  while [ "$d" = "$top" ] || [ "${d#"$top"/}" != "$d" ]; do
    if [ -e "$d/AGENTS.md" ] || [ -L "$d/AGENTS.md" ]; then tool=$d; break; fi
    [ "$d" = "$top" ] && break
    d=$(dirname -- "$d")
  done
  sha=$(git --no-optional-locks -C "$top" log -1 --format=%H -- "$tool" 2>/dev/null)
  [ -n "$sha" ] || { echo unknown; return 0; }
  st=$(git --no-optional-locks -C "$top" status --porcelain --untracked-files=no -- "$tool" 2>/dev/null)
  if [ -n "$st" ]; then echo "$sha-dirty"; else echo "$sha"; fi
}

build_flags() {
  local path=$1 a
  shift
  for a in "$@"; do
    case $a in --build|--version) build_id "$path"; exit 0 ;; esac
  done
}
