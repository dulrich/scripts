#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# npm Supply Chain IOC Scanner
# TeamPCP "Miasma" / "Phantom Gyp" / mini-Shai-Hulud campaign (June 2026)
#
# Detection-only and read-only. This campaign ships a dead-man's switch: a
# gh-token-monitor daemon that recursively deletes files if it detects its
# stolen token was revoked. DO NOT rotate/revoke any credentials until the
# machine is confirmed clean and disconnected. Order matters: CHECK -> ISOLATE
# -> CLEAN -> ROTATE (from a different, trusted machine).
#
# Indicator provenance (all IOCs below trace to one of these advisories):
#   - Microsoft Threat Intelligence, "Preinstall to persistence: Red Hat npm
#     Miasma credential-stealing campaign" (2026-06-02)
#   - StepSecurity, "Miasma npm Supply Chain Attack: Self-Spreading Worm via
#     Phantom Gyp" (wave 2, 2026-06-03)
#   - Snyk, "Miasma Attack Hits Red Hat npm Packages"
#   - Tenable, "Mini Shai-Hulud FAQ" (TeamPCP) -- CVE-2026-45321 (TanStack)
#
# Usage:  ./scan.sh [scan-root]      (default scan-root: $HOME)
# Exit:   0 = clean, 2 = one or more indicators found
# ============================================================================

ROOT="${1:-$HOME}"
DEEP="${DEEP:-false}"
TMP_ROOT="${NPM_IOC_TMP_ROOT:-/tmp}"
HOSTS_FILE="${NPM_IOC_HOSTS_FILE:-/etc/hosts}"
FOUND=0
REVIEWS=0
SECTION=0

# Prefer system tool locations over a user-controlled PATH. This cannot defeat a
# fully rooted host, but it avoids simple PATH shadowing on compromised accounts.
PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# Affected package FAMILIES -- obscure / typosquat names that are attacker-
# specific, so a name/prefix match is high-signal (low false positive). Matched
# by prefix so all poisoned versions are caught even as the worm republishes.
PKG_PREFIXES=(
  "@vapi-ai"
  "ai-sdk-ollama"
  "autotel"
  "awaitly"
  "executable-stories"
  "node-env-resolver"
  "wrangler-deploy"
  "mountly"
  "effect-analyzer"
  "http-uploader-dev"
  "chalk-tempalte"       # typosquat of chalk
  "@deadcode09284814/axios-util"
  "axois-utils"          # typosquat of axios
  "color-style-utils"
)
PKG_RE='@vapi-ai|ai-sdk-ollama|autotel|awaitly|executable-stories|node-env-resolver|wrangler-deploy|mountly|effect-analyzer|http-uploader-dev|chalk-tempalte|@deadcode09284814/axios-util|axois-utils|color-style-utils'

# Exact malicious versions from Microsoft/Snyk for @redhat-cloud-services and
# GitHub/Tenable for CVE-2026-45321. Broad scopes below are REVIEW only.
KNOWN_BAD_PACKAGES=(
  "@redhat-cloud-services/types@3.6.1" "@redhat-cloud-services/types@3.6.2" "@redhat-cloud-services/types@3.6.4"
  "@redhat-cloud-services/frontend-components-utilities@7.4.1" "@redhat-cloud-services/frontend-components-utilities@7.4.2" "@redhat-cloud-services/frontend-components-utilities@7.4.4"
  "@redhat-cloud-services/frontend-components@7.7.2" "@redhat-cloud-services/frontend-components@7.7.3" "@redhat-cloud-services/frontend-components@7.7.5"
  "@redhat-cloud-services/rbac-client@9.0.3" "@redhat-cloud-services/rbac-client@9.0.4" "@redhat-cloud-services/rbac-client@9.0.6"
  "@redhat-cloud-services/javascript-clients-shared@2.0.8" "@redhat-cloud-services/javascript-clients-shared@2.0.9" "@redhat-cloud-services/javascript-clients-shared@2.0.11"
  "@redhat-cloud-services/frontend-components-config-utilities@4.11.2" "@redhat-cloud-services/frontend-components-config-utilities@4.11.3" "@redhat-cloud-services/frontend-components-config-utilities@4.11.5"
  "@redhat-cloud-services/frontend-components-notifications@6.9.2" "@redhat-cloud-services/frontend-components-notifications@6.9.3" "@redhat-cloud-services/frontend-components-notifications@6.9.5"
  "@redhat-cloud-services/tsc-transform-imports@1.2.2" "@redhat-cloud-services/tsc-transform-imports@1.2.4" "@redhat-cloud-services/tsc-transform-imports@1.2.6"
  "@redhat-cloud-services/frontend-components-config@6.11.3" "@redhat-cloud-services/frontend-components-config@6.11.4" "@redhat-cloud-services/frontend-components-config@6.11.6"
  "@redhat-cloud-services/eslint-config-redhat-cloud-services@3.2.1" "@redhat-cloud-services/eslint-config-redhat-cloud-services@3.2.2" "@redhat-cloud-services/eslint-config-redhat-cloud-services@3.2.4"
  "@redhat-cloud-services/host-inventory-client@5.0.3" "@redhat-cloud-services/host-inventory-client@5.0.4" "@redhat-cloud-services/host-inventory-client@5.0.6"
  "@redhat-cloud-services/rule-components@4.7.2" "@redhat-cloud-services/rule-components@4.7.3" "@redhat-cloud-services/rule-components@4.7.5"
  "@redhat-cloud-services/frontend-components-remediations@4.9.2" "@redhat-cloud-services/frontend-components-remediations@4.9.3" "@redhat-cloud-services/frontend-components-remediations@4.9.5"
  "@redhat-cloud-services/frontend-components-translations@4.4.1" "@redhat-cloud-services/frontend-components-translations@4.4.2" "@redhat-cloud-services/frontend-components-translations@4.4.4"
  "@redhat-cloud-services/vulnerabilities-client@2.1.9" "@redhat-cloud-services/vulnerabilities-client@2.1.11"
  "@redhat-cloud-services/frontend-components-advisor-components@3.8.2" "@redhat-cloud-services/frontend-components-advisor-components@3.8.4" "@redhat-cloud-services/frontend-components-advisor-components@3.8.6"
  "@redhat-cloud-services/entitlements-client@4.0.11" "@redhat-cloud-services/entitlements-client@4.0.12" "@redhat-cloud-services/entitlements-client@4.0.14"
  "@redhat-cloud-services/chrome@2.3.1" "@redhat-cloud-services/chrome@2.3.2" "@redhat-cloud-services/chrome@2.3.4"
  "@redhat-cloud-services/notifications-client@6.1.4" "@redhat-cloud-services/notifications-client@6.1.5" "@redhat-cloud-services/notifications-client@6.1.7"
  "@redhat-cloud-services/compliance-client@4.0.3" "@redhat-cloud-services/compliance-client@4.0.4" "@redhat-cloud-services/compliance-client@4.0.6"
  "@redhat-cloud-services/sources-client@3.0.10" "@redhat-cloud-services/sources-client@3.0.11" "@redhat-cloud-services/sources-client@3.0.13"
  "@redhat-cloud-services/integrations-client@6.0.4" "@redhat-cloud-services/integrations-client@6.0.5" "@redhat-cloud-services/integrations-client@6.0.7"
  "@redhat-cloud-services/frontend-components-testing@1.2.1" "@redhat-cloud-services/frontend-components-testing@1.2.2" "@redhat-cloud-services/frontend-components-testing@1.2.4"
  "@redhat-cloud-services/remediations-client@4.0.4" "@redhat-cloud-services/remediations-client@4.0.5" "@redhat-cloud-services/remediations-client@4.0.7"
  "@redhat-cloud-services/insights-client@4.0.4" "@redhat-cloud-services/insights-client@4.0.5" "@redhat-cloud-services/insights-client@4.0.7"
  "@redhat-cloud-services/topological-inventory-client@3.0.10" "@redhat-cloud-services/topological-inventory-client@3.0.11" "@redhat-cloud-services/topological-inventory-client@3.0.13"
  "@redhat-cloud-services/config-manager-client@5.0.4" "@redhat-cloud-services/config-manager-client@5.0.5" "@redhat-cloud-services/config-manager-client@5.0.7"
  "@redhat-cloud-services/hcc-pf-mcp@0.6.1" "@redhat-cloud-services/hcc-pf-mcp@0.6.2" "@redhat-cloud-services/hcc-pf-mcp@0.6.4"
  "@redhat-cloud-services/quickstarts-client@4.0.11" "@redhat-cloud-services/quickstarts-client@4.0.12" "@redhat-cloud-services/quickstarts-client@4.0.14"
  "@redhat-cloud-services/patch-client@4.0.4" "@redhat-cloud-services/patch-client@4.0.5" "@redhat-cloud-services/patch-client@4.0.7"
  "@redhat-cloud-services/hcc-feo-mcp@0.3.1" "@redhat-cloud-services/hcc-feo-mcp@0.3.2" "@redhat-cloud-services/hcc-feo-mcp@0.3.4"
  "@redhat-cloud-services/hcc-kessel-mcp@0.3.1" "@redhat-cloud-services/hcc-kessel-mcp@0.3.2" "@redhat-cloud-services/hcc-kessel-mcp@0.3.4"
  "@tanstack/arktype-adapter@1.166.12" "@tanstack/arktype-adapter@1.166.15"
  "@tanstack/eslint-plugin-router@1.161.9" "@tanstack/eslint-plugin-router@1.161.12"
  "@tanstack/eslint-plugin-start@0.0.4" "@tanstack/eslint-plugin-start@0.0.7"
  "@tanstack/history@1.161.9" "@tanstack/history@1.161.12"
  "@tanstack/nitro-v2-vite-plugin@1.154.12" "@tanstack/nitro-v2-vite-plugin@1.154.15"
  "@tanstack/react-router@1.169.5" "@tanstack/react-router@1.169.8"
  "@tanstack/react-router-devtools@1.166.16" "@tanstack/react-router-devtools@1.166.19"
  "@tanstack/react-router-ssr-query@1.166.15" "@tanstack/react-router-ssr-query@1.166.18"
  "@tanstack/react-start@1.167.68" "@tanstack/react-start@1.167.71"
  "@tanstack/react-start-client@1.166.51" "@tanstack/react-start-client@1.166.54"
  "@tanstack/react-start-rsc@0.0.47" "@tanstack/react-start-rsc@0.0.50"
  "@tanstack/react-start-server@1.166.55" "@tanstack/react-start-server@1.166.58"
  "@tanstack/router-cli@1.166.46" "@tanstack/router-cli@1.166.49"
  "@tanstack/router-core@1.169.5" "@tanstack/router-core@1.169.8"
  "@tanstack/router-devtools@1.166.16" "@tanstack/router-devtools@1.166.19"
  "@tanstack/router-devtools-core@1.167.6" "@tanstack/router-devtools-core@1.167.9"
  "@tanstack/router-generator@1.166.45" "@tanstack/router-generator@1.166.48"
  "@tanstack/router-plugin@1.167.38" "@tanstack/router-plugin@1.167.41"
  "@tanstack/router-ssr-query-core@1.168.3" "@tanstack/router-ssr-query-core@1.168.6"
  "@tanstack/router-utils@1.161.11" "@tanstack/router-utils@1.161.14"
  "@tanstack/router-vite-plugin@1.166.53" "@tanstack/router-vite-plugin@1.166.56"
  "@tanstack/solid-router@1.169.5" "@tanstack/solid-router@1.169.8"
  "@tanstack/solid-router-devtools@1.166.16" "@tanstack/solid-router-devtools@1.166.19"
  "@tanstack/solid-router-ssr-query@1.166.15" "@tanstack/solid-router-ssr-query@1.166.18"
  "@tanstack/solid-start@1.167.65" "@tanstack/solid-start@1.167.68"
  "@tanstack/solid-start-client@1.166.50" "@tanstack/solid-start-client@1.166.53"
  "@tanstack/solid-start-server@1.166.54" "@tanstack/solid-start-server@1.166.57"
  "@tanstack/start-client-core@1.168.5" "@tanstack/start-client-core@1.168.8"
  "@tanstack/start-fn-stubs@1.161.9" "@tanstack/start-fn-stubs@1.161.12"
  "@tanstack/start-plugin-core@1.169.23" "@tanstack/start-plugin-core@1.169.26"
  "@tanstack/start-server-core@1.167.33" "@tanstack/start-server-core@1.167.36"
  "@tanstack/start-static-server-functions@1.166.44" "@tanstack/start-static-server-functions@1.166.47"
  "@tanstack/start-storage-context@1.166.38" "@tanstack/start-storage-context@1.166.41"
  "@tanstack/valibot-adapter@1.166.12" "@tanstack/valibot-adapter@1.166.15"
  "@tanstack/virtual-file-routes@1.161.10" "@tanstack/virtual-file-routes@1.161.13"
  "@tanstack/vue-router@1.169.5" "@tanstack/vue-router@1.169.8"
  "@tanstack/vue-router-devtools@1.166.16" "@tanstack/vue-router-devtools@1.166.19"
  "@tanstack/vue-router-ssr-query@1.166.15" "@tanstack/vue-router-ssr-query@1.166.18"
  "@tanstack/vue-start@1.167.61" "@tanstack/vue-start@1.167.64"
  "@tanstack/vue-start-client@1.166.46" "@tanstack/vue-start-client@1.166.49"
  "@tanstack/vue-start-server@1.166.50" "@tanstack/vue-start-server@1.166.53"
  "@tanstack/zod-adapter@1.166.12" "@tanstack/zod-adapter@1.166.15"
)

# Broad, LEGITIMATE scopes where only specific versions were compromised
# (mini-Shai-Hulud / CVE-2026-45321 for @tanstack). These are widely-used
# libraries (e.g. @tanstack/react-query), so presence is NOT proof of
# compromise -- it is a watchlist. Reported as REVIEW only; cross-check the
# exact versions in your lockfile against the Tenable/Snyk advisories.
WATCH_RE='@redhat-cloud-services|@tanstack|@uipath|@mistralai|@opensearch-project|@antv|@squawk'

# Attacker-INVENTED file names. These do not normally exist, so existence alone
# is high-signal. Executed via "bun run", evading node-only monitoring.
SETUP_FILES=(
  ".claude/setup.mjs"
  ".vscode/setup.mjs"
  ".cursor/rules/setup.mdc"
  ".github/setup.js"
)

# Legitimate config files the worm INJECTS into (it appends a malicious hook
# rather than creating the file). Existence is normal; only matching content is
# malicious, so these are content-scanned, not flagged on presence.
INJECT_CONFIGS=(
  ".claude/settings.json"
  ".claude/settings.local.json"
  ".gemini/settings.json"
  ".cursor/settings.json"
)

# High-signal string IOCs (C2 account, magic search keywords, payload internals).
IOC_RE='Miasma|Shai-Hulud|liuende501|thebeautifulmarchoftime|IfYouInvalidateThisTokenItWillNukeTheComputerOfTheOwner|gh-token-monitor'

# High-signal code markers found inside the obfuscated JS payload / binding.gyp.
PAYLOAD_MARKERS='globalThis\.getBunPath|createDecipheriv\("aes-128-gcm"|<!\(node index\.js|oven-sh/bun/releases/download/bun-v1\.3\.13'

hr() { printf '%*s\n' 65 '' | tr ' ' '='; }
section() { SECTION=$((SECTION+1)); printf '\n[%d] %s\n' "$SECTION" "$1"; }
hit() { FOUND=1; printf '  HIT: %s\n' "$*"; }
review() { REVIEWS=$((REVIEWS+1)); printf '  REVIEW: %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

dedupe_existing_files() {
  local seen="" f real
  for f in "$@"; do
    [ -f "$f" ] || continue
    real="$(readlink -f "$f" 2>/dev/null || printf '%s' "$f")"
    case "
$seen
" in
      *"
$real
"*) continue ;;
    esac
    seen="${seen}${real}
"
    printf '%s\0' "$f"
  done
}

json_string_field() {
  local field="$1" file="$2"
  perl -0777 -ne 'BEGIN { $f = shift @ARGV } print $1 if /"\Q$f\E"\s*:\s*"([^"]+)"/s' "$field" "$file" 2>/dev/null
}

known_bad_exact() {
  local needle="$1@$2" i
  for i in "${KNOWN_BAD_PACKAGES[@]}"; do
    [ "$i" = "$needle" ] && return 0
  done
  return 1
}

prefix_hit_pkg() {
  local name="$1" p
  for p in "${PKG_PREFIXES[@]}"; do
    case "$name" in
      "$p"|"$p"/*|"$p"-*) return 0 ;;
    esac
  done
  return 1
}

watch_pkg() {
  case "$1" in
    @redhat-cloud-services/*|@tanstack/*|@uipath/*|@mistralai/*|@opensearch-project/*|@antv/*|@squawk/*) return 0 ;;
  esac
  return 1
}

report_package_reference() {
  local name="$1" version="$2" where="$3"
  [ -n "$name" ] || return 0

  if [ -n "$version" ] && known_bad_exact "$name" "$version"; then
    package_hits=$((package_hits+1))
    hit "known malicious package version $name@$version in $where"
  elif prefix_hit_pkg "$name"; then
    package_hits=$((package_hits+1))
    if [ -n "$version" ]; then
      hit "affected package family '$name'@$version present in $where"
    else
      hit "affected package family '$name' present in $where"
    fi
  elif watch_pkg "$name"; then
    if [ -n "$version" ]; then
      review "watchlist package present (verify exact version vs advisory): $name@$version in $where"
    else
      review "watchlist package present (verify exact version vs advisory): $name in $where"
    fi
  fi
}

scan_lock_pairs() {
  local lock="$1"
  perl -0777 -ne '
    while (/"node_modules\/((?:@[^\/"]+\/)?[^\/"]+)"\s*:\s*\{.*?"version"\s*:\s*"([^"]+)"/sg) {
      print "$1\t$2\n";
    }
    while (/^"?((?:@[^\/\s"]+\/)?[^@\s",:]+)@(?:npm:)?([^",:\s]+)[^"]*"?\s*:/mg) {
      print "$1\t$2\n";
    }
    while (/^\s{2,}\/((?:@[^\/\s:]+\/)?[^@\s:]+)@([^:\s]+):/mg) {
      print "$1\t$2\n";
    }
  ' "$lock" 2>/dev/null
}

host="$(hostname 2>/dev/null || echo unknown)"
user="${USER:-${USERNAME:-unknown}}"
os="$(uname -s 2>/dev/null || echo unknown)"
started="$(date -Iseconds 2>/dev/null || date)"

hr
echo " npm Supply Chain IOC Scanner (Miasma / Phantom Gyp / mini-Shai-Hulud)"
echo " ${started} | bash | cross-platform-ish | detection-only"
hr
printf '  Host     : %s\n' "$host"
printf '  User     : %s\n' "$user"
printf '  OS       : %s\n' "$os"
printf '  Scan root: %s\n' "$ROOT"
printf '  Deep     : %s\n' "$DEEP"
printf '  TMP root : %s\n' "$TMP_ROOT"
printf '  Tools    : find=%s grep=%s perl=%s ps=%s\n' \
  "$(command -v find 2>/dev/null || echo missing)" \
  "$(command -v grep 2>/dev/null || echo missing)" \
  "$(command -v perl 2>/dev/null || echo missing)" \
  "$(command -v ps 2>/dev/null || echo missing)"

section "Affected package families (installed trees)"
projects_found=0
package_hits=0
binding_gyp_hits=0

while IFS= read -r -d '' pkgjson; do
  dir="$(dirname "$pkgjson")"
  [ -d "$dir/node_modules" ] || continue
  projects_found=$((projects_found+1))
done < <(find "$ROOT" \
  \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
  -name package.json -print0 2>/dev/null)

while IFS= read -r -d '' modpkg; do
  name="$(json_string_field name "$modpkg")"
  version="$(json_string_field version "$modpkg")"
  report_package_reference "$name" "$version" "$modpkg"
done < <(find "$ROOT" -path '*/node_modules/*/package.json' -print0 2>/dev/null)

info "$projects_found npm project(s) found"
info "$package_hits affected-package match(es) found"

section "Phantom Gyp payload in node_modules (weaponized binding.gyp)"
# Wave-2 vector: a 157-byte binding.gyp triggers 'node-gyp rebuild' on install,
# weaponizing gyp command substitution to run a dropped SCRIPT FILE:
#   "<!(node index.js > /dev/null 2>&1 && echo stub.c)"
# NOTE: binding.gyp is a NORMAL file for native modules (better-sqlite3,
# node-pty, keytar, ...), and the idiom "<!(node -p \"require('node-addon-api')
# .include_dir\")" is legitimate -- that runs node -p on an EXPRESSION, not a
# .js file. So the discriminators are: (a) command substitution that runs node
# on a .js script, and (b) the definitive payload markers in the root index.js.
gyp_total=0
while IFS= read -r -d '' bg; do
  gyp_total=$((gyp_total+1))
  pkgdir="$(dirname "$bg")"
  rootidx="$pkgdir/index.js"
  bad=0
  # (a) definitive: obfuscated-payload markers in the index.js beside binding.gyp
  if [ -f "$rootidx" ] && grep -Eq "$PAYLOAD_MARKERS" "$rootidx" 2>/dev/null; then
    bad=1; hit "payload code marker in root index.js beside binding.gyp: $rootidx"
    grep -noE "$PAYLOAD_MARKERS" "$rootidx" 2>/dev/null | sort -u | sed 's/^/    /' | head -n 5
  # (b) binding.gyp runs node on a .js script (not the legit "node -p <expr>")
  elif grep -Eq '<!\(\s*node\b[^)]*\.js\b' "$bg" 2>/dev/null; then
    bad=1; hit "binding.gyp runs a .js via command substitution (not node -p idiom): $bg"
    grep -nE '<!\(\s*node\b[^)]*\.js\b' "$bg" 2>/dev/null | sed 's/^/    /' | head -n 5
    if [ -f "$rootidx" ]; then
      sz="$(wc -c < "$rootidx" 2>/dev/null | tr -d ' ')"
      [ -n "${sz:-}" ] && info "    (root index.js is ${sz} bytes)"
    fi
  fi
  binding_gyp_hits=$((binding_gyp_hits+bad))
done < <(find "$ROOT" -path '*/node_modules/*/binding.gyp' -print0 2>/dev/null)
info "$gyp_total binding.gyp file(s) seen; $binding_gyp_hits weaponized"

section "Affected packages referenced in lockfiles"
while IFS= read -r -d '' lock; do
  while IFS="$(printf '\t')" read -r name version; do
    report_package_reference "$name" "$version" "$lock"
  done < <(scan_lock_pairs "$lock")

  if grep -Eq "$PKG_RE" "$lock" 2>/dev/null; then
    hit "affected package reference in $lock"
    grep -nE "$PKG_RE" "$lock" 2>/dev/null | sed 's/^/    /' | head -n 40
  fi
  # Broad legit scopes: report for manual version cross-check, not as a HIT.
  if grep -Eq "$WATCH_RE" "$lock" 2>/dev/null; then
    scopes="$(grep -oE "$WATCH_RE" "$lock" 2>/dev/null | sort -u | paste -sd' ' -)"
    review "watchlist scope(s) present (legit libs; verify versions vs advisory): $lock"
    info "      scopes: $scopes"
  fi
done < <(find "$ROOT" \
  \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
  \( -name package-lock.json -o -name npm-shrinkwrap.json -o -name yarn.lock -o -name pnpm-lock.yaml \) \
  -print0 2>/dev/null)

section "Injected AI-assistant / editor backdoor files"
# Attacker-invented file names -- existence is the finding. They execute on
# session/folder open via 'bun run', so a node-only monitor never sees them.
for rel in "${SETUP_FILES[@]}"; do
  base="$(basename "$rel")"
  while IFS= read -r -d '' f; do
    hit "injected setup file ($rel): $f"
    if grep -Eq "$PAYLOAD_MARKERS|$IOC_RE|bun run" "$f" 2>/dev/null; then
      grep -nE "$PAYLOAD_MARKERS|$IOC_RE|bun run" "$f" 2>/dev/null | sed 's/^/    /' | head -n 10
    fi
  done < <(find "$ROOT" \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    -name "$base" -print0 2>/dev/null \
    | { while IFS= read -r -d '' p; do case "$p" in */$rel) printf '%s\0' "$p" ;; esac; done; })
done
# Legit config files (e.g. .gemini/settings.json) -- only malicious CONTENT counts.
for rel in "${INJECT_CONFIGS[@]}"; do
  base="$(basename "$rel")"
  while IFS= read -r -d '' f; do
    if grep -Eq "$PAYLOAD_MARKERS|$IOC_RE|setup\.mjs|bun run" "$f" 2>/dev/null; then
      hit "malicious content injected into config ($rel): $f"
      grep -nE "$PAYLOAD_MARKERS|$IOC_RE|setup\.mjs|bun run" "$f" 2>/dev/null | sed 's/^/    /' | head -n 10
    fi
  done < <(find "$ROOT" \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    -name "$base" -print0 2>/dev/null \
    | { while IFS= read -r -d '' p; do case "$p" in */$rel) printf '%s\0' "$p" ;; esac; done; })
done

section "Claude Code / OpenCode persistence (SessionStart hooks)"
agent_config_files=(
  "$HOME/.claude/settings.json"
  "$HOME/.claude/settings.local.json"
  "$ROOT/.claude/settings.json"
  "$ROOT/.opencode/opencode.json"
  "$ROOT/.opencode/config.json"
)

while IFS= read -r -d '' cfg; do
  if grep -Eq "$IOC_RE|setup\.mjs|bun run" "$cfg" 2>/dev/null; then
    hit "malicious agent persistence signature: $cfg"
    grep -nE "$IOC_RE|setup\.mjs|bun run|SessionStart" "$cfg" 2>/dev/null | sed 's/^/    /'
  elif grep -q 'SessionStart' "$cfg" 2>/dev/null; then
    # A SessionStart hook with no known-bad signature is NOT proof of clean.
    # The real payload runs 'bun run .claude/setup.mjs'; manually confirm the
    # command is one you added.
    review "SessionStart hook present (verify the command is yours): $cfg"
    grep -nE 'SessionStart|command' "$cfg" 2>/dev/null | sed 's/^/    /' | head -n 20
  fi
done < <(dedupe_existing_files "${agent_config_files[@]}")

for d in "$ROOT/.claude" "$ROOT/.opencode" "$HOME/.claude" "$HOME/.cursor" "$HOME/.gemini"; do
  [ -d "$d" ] || continue
  while IFS= read -r -d '' f; do
    if grep -Eq "$IOC_RE|$PAYLOAD_MARKERS" "$f" 2>/dev/null; then
      hit "agent-config IOC: $f"
      grep -nE "$IOC_RE|$PAYLOAD_MARKERS" "$f" 2>/dev/null | sed 's/^/    /'
    fi
  done < <(find "$d" \
    \( -path '*/projects/*' -o -path '*/plans/*' -o -path '*/todos/*' -o -name '*.jsonl' -o -path '*/logs/*' -o -path '*/history/*' \) -prune -o \
    -type f \
    \( -name '*.json' -o -name '*.jsonc' -o -name '*.mjs' -o -name '*.mdc' -o -name '*.toml' -o -name '*.yaml' -o -name '*.yml' \) \
    -print0 2>/dev/null)
done

section "VS Code task persistence (folderOpen auto-run)"
while IFS= read -r -d '' task; do
  if grep -Eq 'folderOpen' "$task" 2>/dev/null; then
    hit "folderOpen task persistence: $task"
    grep -nE 'folderOpen|setup\.mjs|bun' "$task" 2>/dev/null | sed 's/^/    /'
  fi
done < <(find "$ROOT" \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
  -path '*/.vscode/tasks.json' -print0 2>/dev/null)

section "gh-token-monitor dead-man's-switch daemon"
# Polls GitHub every ~60s; recursively deletes files if it sees its token
# revoked. Listing only -- do not stop/remove until the machine is isolated.
daemon_seen=0
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-units --all 2>/dev/null | grep -i 'gh-token-monitor'; then daemon_seen=1; fi
  if systemctl --user list-units --all 2>/dev/null | grep -i 'gh-token-monitor'; then daemon_seen=1; fi
fi
for ud in "$HOME/.config/systemd/user" "/etc/systemd/system" "/etc/systemd/user" "$HOME/Library/LaunchAgents" "/Library/LaunchAgents" "/Library/LaunchDaemons"; do
  [ -d "$ud" ] || continue
  while IFS= read -r -d '' u; do
    daemon_seen=1
    hit "gh-token-monitor unit/agent: $u"
  done < <(find "$ud" -maxdepth 1 -type f -iname '*gh-token-monitor*' -print0 2>/dev/null)
  # also grep contents of unit files for the marker
  while IFS= read -r -d '' u; do
    if grep -qi 'gh-token-monitor' "$u" 2>/dev/null; then
      daemon_seen=1
      hit "gh-token-monitor reference inside: $u"
    fi
  done < <(find "$ud" -maxdepth 1 -type f \( -name '*.service' -o -name '*.plist' \) -print0 2>/dev/null)
done
if command -v launchctl >/dev/null 2>&1; then
  if launchctl list 2>/dev/null | grep -i 'gh-token-monitor'; then daemon_seen=1; FOUND=1; fi
fi
[ "$daemon_seen" -eq 0 ] && info "no gh-token-monitor daemon found"

section "Bun runtime artifacts (evasion: payload runs off-Node)"
bun_seen=0
while IFS= read -r -d '' b; do
  bun_seen=1
  hit "bun binary in temp dir (worm staging): $b"
done < <(find "$TMP_ROOT" -maxdepth 2 -type f -name 'bun' \( -path '*/b-*' -o -path '*/.b_*' \) -print0 2>/dev/null)
while IFS= read -r -d '' pjs; do
  bun_seen=1
  hit "temp JavaScript payload artifact: $pjs"
done < <(find "$TMP_ROOT" -maxdepth 1 -type f -name 'p*.js' -print0 2>/dev/null)
if command -v ps >/dev/null 2>&1; then
  # Only flag bun executing from the worm's mktemp staging dir (/tmp/b-XXXX/bun);
  # a bare "bun run" would match legitimate Bun usage.
  # shellcheck disable=SC2009  # ps|grep is portable; pgrep -f not guaranteed everywhere
  if ps -eo args 2>/dev/null | grep -E "$TMP_ROOT/(\.?b[-_][^ ]*)/bun" | grep -v grep; then
    bun_seen=1; FOUND=1
  fi
fi
[ "$bun_seen" -eq 0 ] && info "no suspicious bun artifacts found"

section "Passwordless-sudo persistence"
if [ -d /etc/sudoers.d ]; then
  sudo_seen=0
  while IFS= read -r sf; do
    sudo_seen=1
    review "NOPASSWD rule present (confirm it is intentional): $sf"
  done < <(grep -RIl 'NOPASSWD' /etc/sudoers.d 2>/dev/null | grep -v -e '/README')
  if [ "$sudo_seen" -eq 0 ]; then
    info "sudoers.d check skipped or no NOPASSWD rules readable"
  fi
else
  info "no /etc/sudoers.d directory"
fi

section "Hosts file DNS redirection"
if [ -f "$HOSTS_FILE" ]; then
  if grep -Ei '^[[:space:]]*(127\.0\.0\.1|0\.0\.0\.0)[[:space:]].*(github\.com|api\.github\.com|registry\.npmjs\.org|npmjs\.org|nodejs\.org|api\.anthropic\.com|oven-sh)' "$HOSTS_FILE" 2>/dev/null; then
    review "developer-service hostname redirection in hosts file (verify intentional): $HOSTS_FILE"
  else
    info "no suspicious developer-service hosts redirection found"
  fi
else
  info "hosts file not readable: $HOSTS_FILE"
fi

section "Payload code markers in source / config trees"
while IFS= read -r -d '' f; do
  if grep -Eq "$PAYLOAD_MARKERS|$IOC_RE" "$f" 2>/dev/null; then
    hit "payload/IOC marker: $f"
    grep -nE "$PAYLOAD_MARKERS|$IOC_RE" "$f" 2>/dev/null | sed 's/^/    /' | head -n 5
  fi
done < <(find "$ROOT" \
  \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
  -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name 'binding.gyp' \) \
  -print0 2>/dev/null)

section "Agent context files -- zero-width character injection"
# NOTE: U+FEFF as the very first byte is a normal UTF-8 BOM and U+200D is part
# of legitimate emoji ZWJ sequences, so match these only mid-line and report
# them for review rather than as a hard hit. Test perl's OUTPUT, not its exit
# status -- perl -ne always exits 0 whether or not the pattern matched.
while IFS= read -r -d '' ctx; do
  zw="$(perl -CSD -ne 'print "$ARGV:$.: $_" if /\S[\x{200B}\x{200C}\x{200D}\x{FEFF}]|[\x{200B}\x{200C}\x{200D}\x{FEFF}]\S/' "$ctx" 2>/dev/null)"
  if [ -n "$zw" ]; then
    review "zero-width character inside text (often benign emoji/BOM; verify): $ctx"
    printf '%s\n' "$zw" | sed 's/^/    /' | head -n 5
  fi
done < <(find "$ROOT" \
  \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
  \( -name CLAUDE.md -o -name AGENTS.md -o -name settings.json -o -name .cursorrules \) \
  -print0 2>/dev/null)

section "Shell profiles -- unexpected bun/runtime download"
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile"; do
  if [ -f "$rc" ] && grep -Eq 'oven-sh/bun|getBunPath|gh-token-monitor' "$rc" 2>/dev/null; then
    hit "shell RC IOC: $rc"
    grep -nE 'oven-sh/bun|getBunPath|gh-token-monitor' "$rc" 2>/dev/null | sed 's/^/    /'
  fi
done

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

  Cannot be checked locally -- verify these by hand on github.com:
   - Security log (github.com/settings/security-log) for repos/tokens/runners
     you did not create.
   - Exfil repos named like 'adjective-creature-<0-99999>' (e.g. nemean-hydra-34343)
     or with description 'Miasma: The Spreading Blight'; files at
     results/results-{timestamp}.json.
   - npm publish history / GitHub audit log for versions or commits you did not make.

  If anything fired above: DO NOT revoke or rotate tokens yet.
   1. Disconnect this machine from the network (dead-man's switch wipes $HOME
      if it sees its access cut).
   2. Screenshot the evidence, then remove the injected files / daemon.
   3. ONLY THEN rotate credentials -- from a different, trusted machine.

EOF

[ "$FOUND" -eq 0 ] && exit 0 || exit 2
