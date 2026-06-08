#!/usr/bin/env bash
# Smoke tests for ../scan.sh
#
# Builds throwaway fixture trees, runs the scanner against them, and asserts the
# right things fire (and the wrong things don't). Hermetic w.r.t. the agent-
# config sections: HOME is redirected to an empty fixture dir so the host's real
# ~/.claude etc. cannot influence results. System-global sections (systemd,
# /etc/sudoers.d, /tmp bun staging) assume a clean host -- they only emit REVIEW
# or info on a clean machine, never a HIT.
#
# Usage:  ./tests/smoke.sh
# Exit:   0 = all tests passed, 1 = one or more failures
#
# The scan.sh static check (shellcheck) runs automatically when that tool is
# installed (expected in CI/dev); it is skipped with a warning when absent.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$(cd "$HERE/.." && pwd)/scan.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL - %s\n' "$1"; }

assert_eq() { # actual expected desc
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}
assert_contains() { # haystack needle desc
  case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)" ;; esac
}
assert_not_contains() { # haystack needle desc
  case "$1" in *"$2"*) bad "$3 (unexpected: $2)" ;; *) ok "$3" ;; esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"

run_scan() { # root -> sets global OUT and CODE
  OUT="$(HOME="$FAKEHOME" bash "$SCAN" "$1" 2>&1)"; CODE=$?
}

# ---------------------------------------------------------------------------
echo "[shellcheck] scan.sh (optional)"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SCAN"; then ok "shellcheck clean"; else bad "shellcheck reported issues"; fi
else
  printf '  WARN - shellcheck not installed; skipping (install it for full coverage)\n'
fi

# ---------------------------------------------------------------------------
echo "[regression] no fabricated indicators in scan.sh"
if grep -qE 'ddjidd564|p2024_integrity|router_init|router_runtime|tanstack_runner|dev-env-bootstrapper' "$SCAN"; then
  bad "fabricated indicator present in scan.sh"
else
  ok "no fabricated indicators"
fi

# ---------------------------------------------------------------------------
echo "[positive] malicious fixture must HIT and exit 2"
POS="$WORK/pos"; P="$POS/proj"
mkdir -p "$P/node_modules/evil" "$P/node_modules/natmod" "$P/.claude" "$P/.vscode" "$P/.gemini"
# weaponized binding.gyp: runs a .js script via command substitution
printf '{"targets":[{"sources":["<!(node index.js > /dev/null 2>&1 && echo stub.c)"]}]}' \
  > "$P/node_modules/evil/binding.gyp"
printf 'globalThis.getBunPath=function(){}\n' > "$P/node_modules/evil/index.js"
# legit native module using the node-addon-api idiom -- must NOT be flagged
printf '{"targets":[{"include_dirs":["<!(node -p \\"require(\\047node-addon-api\\047).include_dir\\")"],"sources":["src/x.cpp"]}]}' \
  > "$P/node_modules/natmod/binding.gyp"
# lockfile: @vapi-ai (HIT family) + @tanstack (REVIEW watchlist)
printf '{"packages":{"node_modules/@vapi-ai/server-sdk":{"version":"1.2.2"},"node_modules/@tanstack/react-query":{"version":"5.0.0"}}}' \
  > "$P/package-lock.json"
printf '{"name":"proj"}' > "$P/package.json"
printf 'payload\n' > "$P/.claude/setup.mjs"                              # invented name -> HIT
printf '{"theme":"dark"}' > "$P/.gemini/settings.json"                   # legit config -> no HIT
printf '{"tasks":[{"runOptions":{"runOn":"folderOpen"},"command":"x"}]}' > "$P/.vscode/tasks.json"

run_scan "$POS"
assert_eq "$CODE" "2" "positive: exit code is 2"
assert_contains "$OUT" "payload code marker in root index.js"            "positive: weaponized binding.gyp/index.js"
assert_contains "$OUT" "2 binding.gyp file(s) seen; 1 weaponized"        "positive: legit node-addon-api binding.gyp not flagged"
assert_contains "$OUT" "injected setup file (.claude/setup.mjs)"         "positive: invented setup file"
assert_contains "$OUT" "folderOpen task persistence"                     "positive: vscode folderOpen task"
assert_contains "$OUT" "affected package reference"                      "positive: @vapi-ai lockfile HIT"
assert_contains "$OUT" "REVIEW: watchlist scope"                         "positive: @tanstack is REVIEW not HIT"
assert_not_contains "$OUT" "malicious content injected into config"      "positive: plain .gemini config not flagged"

# ---------------------------------------------------------------------------
echo "[negative] clean fixture must be CLEAN and exit 0"
NEG="$WORK/neg"; N="$NEG/proj"
mkdir -p "$N/node_modules/natmod" "$N/.gemini"
printf '{"targets":[{"include_dirs":["<!(node -p \\"require(\\047node-addon-api\\047).include_dir\\")"],"sources":["src/x.cpp"]}]}' \
  > "$N/node_modules/natmod/binding.gyp"
printf '{"theme":"dark"}' > "$N/.gemini/settings.json"
printf '{"packages":{"node_modules/@tanstack/react-query":{"version":"5.0.0"}}}' > "$N/package-lock.json"
printf '{"name":"proj"}' > "$N/package.json"

run_scan "$NEG"
assert_eq "$CODE" "0" "negative: exit code is 0"
assert_contains "$OUT" "CLEAN"                                           "negative: verdict is CLEAN"
assert_not_contains "$OUT" "HIT:"                                        "negative: no HIT lines"

# ---------------------------------------------------------------------------
echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
