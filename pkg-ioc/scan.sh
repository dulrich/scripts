#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Package supply-chain IOC scanner -- ROUTER
# TeamPCP "Miasma" / "Phantom Gyp" / "Shai-Hulud" / "Hades" campaign (June 2026)
#
# This is a dispatcher. Ecosystem-specific detection lives in lib/<eco>.sh and
# shared, host-level detection in lib/common.sh; all are sourced into this one
# process so FOUND/REVIEWS accumulate into a single verdict and one exit code.
#
# Detection-only and read-only. This campaign ships a dead-man's switch: a
# gh-token-monitor daemon that recursively deletes files if it detects its
# stolen token was revoked. DO NOT rotate/revoke any credentials until the
# machine is confirmed clean and disconnected. Order matters: CHECK -> ISOLATE
# -> CLEAN -> ROTATE (from a different, trusted machine).
#
# Usage:  ./scan.sh [--ecosystem npm|pypi|all] [scan-root]
#         ./scan.sh [scan-root]                 (ecosystem defaults to "all")
# Exit:   0 = clean, 2 = one or more indicators found
# ============================================================================

ECOSYSTEM="all"
ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ecosystem) ECOSYSTEM="${2:-all}"; shift 2 ;;
    --ecosystem=*) ECOSYSTEM="${1#*=}"; shift ;;
    -h|--help)
      sed -n '5,20p' "$0"; exit 0 ;;
    *) ROOT="$1"; shift ;;
  esac
done
case "$ECOSYSTEM" in
  npm|pypi|all) ;;
  *) printf 'unknown --ecosystem "%s" (want: npm|pypi|all)\n' "$ECOSYSTEM" >&2; exit 64 ;;
esac

ROOT="${ROOT:-$HOME}"
DEEP="${DEEP:-false}"
# Temp roots. The loaders stage in the PLATFORM temp dir (mkdtempSync(tmpdir())
# in the JS stage, tempfile.gettempdir() in the .pth loader): that is /tmp on
# Linux/BSD but $TMPDIR (/var/folders/...) on macOS, so both are scanned.
# NPM_IOC_TMP_ROOT pins a single root (the test harness uses this to stay
# hermetic).
if [ -n "${NPM_IOC_TMP_ROOT:-}" ]; then
  TMP_ROOTS=("${NPM_IOC_TMP_ROOT%/}")
else
  TMP_ROOTS=(/tmp)
  if [ -n "${TMPDIR:-}" ] && [ "${TMPDIR%/}" != "/tmp" ] && [ -d "${TMPDIR%/}" ]; then
    TMP_ROOTS+=("${TMPDIR%/}")
  fi
fi
# The sourced common module consumes this router-owned fixture override.
# shellcheck disable=SC2034
HOSTS_FILE="${NPM_IOC_HOSTS_FILE:-/etc/hosts}"
FOUND=0
REVIEWS=0
# The sourced section helper owns this shared counter.
# shellcheck disable=SC2034
SECTION=0

# Prefer system tool locations over a user-controlled PATH. This cannot defeat a
# fully rooted host, but it avoids simple PATH shadowing on compromised accounts.
PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# Resolve our own directory (the repo's $here idiom) so the lib files load no
# matter where scan.sh is invoked or symlinked from.
SELF="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
LIBDIR="$(dirname "$SELF")/lib"
# These runtime-resolved includes are followed by the smoke suite's `-x` pass;
# the repository's per-file gate intentionally runs without external sources.
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
. "$LIBDIR/common.sh"
# shellcheck source=lib/npm.sh
# shellcheck disable=SC1091
. "$LIBDIR/npm.sh"
# shellcheck source=lib/pypi.sh
# shellcheck disable=SC1091
. "$LIBDIR/pypi.sh"

host="$(hostname 2>/dev/null || echo unknown)"
user="${USER:-${USERNAME:-unknown}}"
os="$(uname -s 2>/dev/null || echo unknown)"
started="$(date -Iseconds 2>/dev/null || date)"

hr
echo " Package Supply Chain IOC Scanner (Miasma / Phantom Gyp / Shai-Hulud / Hades)"
echo " ${started} | bash | cross-platform-ish | detection-only"
hr
printf '  Host     : %s\n' "$host"
printf '  User     : %s\n' "$user"
printf '  OS       : %s\n' "$os"
printf '  Scan root: %s\n' "$ROOT"
printf '  Ecosystem: %s\n' "$ECOSYSTEM"
printf '  Deep     : %s\n' "$DEEP"
printf '  TMP roots: %s\n' "${TMP_ROOTS[*]}"
printf '  Tools    : find=%s grep=%s perl=%s ps=%s\n' \
  "$(command -v find 2>/dev/null || echo missing)" \
  "$(command -v grep 2>/dev/null || echo missing)" \
  "$(command -v perl 2>/dev/null || echo missing)" \
  "$(command -v ps 2>/dev/null || echo missing)"

case "$ECOSYSTEM" in
  npm|all)  run_npm_checks "$ROOT" ;;
esac
case "$ECOSYSTEM" in
  pypi|all) run_pypi_checks "$ROOT" ;;
esac

# Host-level, campaign-wide checks run once regardless of ecosystem selection.
run_common_checks "$ROOT"

printf '\n'
hr
if [ "$FOUND" -eq 0 ]; then
  echo " CLEAN -- No definitive local indicators of compromise detected."
else
  echo " COMPROMISED / SUSPICIOUS -- One or more indicators detected."
fi
[ "$REVIEWS" -gt 0 ] && echo " ($REVIEWS item(s) flagged REVIEW above -- not definitive, but confirm by hand)"
hr

cat <<'EOF'

  Cannot be checked locally -- verify these by hand on github.com / your registries:
   - Security log (github.com/settings/security-log) for repos/tokens/runners
     you did not create.
   - Exfil repos named like 'adjective-creature-<0-99999>' (e.g. nemean-hydra-34343)
     or with description 'Miasma: The Spreading Blight'; files at
     results/results-{timestamp}.json.
   - npm / PyPI publish history and GitHub audit log for versions or commits you
     did not make.

  If anything fired above: DO NOT revoke or rotate tokens yet.
   1. Disconnect this machine from the network (dead-man's switch wipes $HOME
      if it sees its access cut).
   2. Screenshot the evidence, then remove the injected files / daemon.
   3. ONLY THEN rotate credentials -- from a different, trusted machine.

EOF

[ "$FOUND" -eq 0 ] && exit 0 || exit 2
