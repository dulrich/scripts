# shellcheck shell=bash
# ============================================================================
# pkg-ioc :: lib/npm.sh
#
# npm leg of the TeamPCP "Miasma" / "Phantom Gyp" / mini-Shai-Hulud campaign.
# Sourced by scan.sh; exposes run_npm_checks "<root>". Detection-only.
#
# Indicator provenance (npm leg):
#   - Microsoft Threat Intelligence, "Preinstall to persistence: Red Hat npm
#     Miasma credential-stealing campaign" (2026-06-02)
#   - StepSecurity, "Miasma npm Supply Chain Attack: Self-Spreading Worm via
#     Phantom Gyp" (wave 2, 2026-06-03)
#   - Snyk, "Miasma Attack Hits Red Hat npm Packages"
#   - Tenable, "Mini Shai-Hulud FAQ" (TeamPCP) -- CVE-2026-45321 (TanStack)
# ============================================================================

# Affected package FAMILIES -- obscure / typosquat names that are attacker-
# specific, so a name/prefix match is high-signal (low false positive). Matched
# by prefix so all poisoned versions are caught even as the worm republishes.
PKG_PREFIXES=(
  "@redhat-cloud-services"
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
  "@evolvconsulting/evolv-coder-lite"   # StepSecurity affected-packages table
  "@jagreehal/workflow"                 # StepSecurity affected-packages table
)
PKG_RE='@redhat-cloud-services|@vapi-ai|ai-sdk-ollama|autotel|awaitly|executable-stories|node-env-resolver|wrangler-deploy|mountly|effect-analyzer|http-uploader-dev|chalk-tempalte|@deadcode09284814/axios-util|axois-utils|color-style-utils|@evolvconsulting/evolv-coder-lite|@jagreehal/workflow'

# Exact malicious versions from Microsoft/Snyk for @redhat-cloud-services and
# GitHub/Tenable for CVE-2026-45321. Broad scopes below are REVIEW only.
KNOWN_BAD_PACKAGES=(
  "@evolvconsulting/evolv-coder-lite@1.2.0"
  "@jagreehal/workflow@1.16.1"
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
# (mini-Shai-Hulud / CVE-2026-45321 for @tanstack). Widely-used libraries, so
# presence is NOT proof of compromise -- a REVIEW watchlist. @redhat-cloud-services
# is deliberately NOT here (see AGENTS.md FP rule 2): it is a HIT scope.
WATCH_RE='@tanstack|@uipath|@mistralai|@opensearch-project|@antv|@squawk'

# Attacker-INVENTED file names. These do not normally exist, so existence alone
# is high-signal. Executed via "bun run", evading node-only monitoring.
SETUP_FILES=(
  ".claude/setup.mjs"
  ".vscode/setup.mjs"
  ".cursor/rules/setup.mdc"
  ".github/setup.js"
)

# Legitimate config files the worm INJECTS into. Existence is normal; only
# matching content is malicious, so content-scanned, not flagged on presence.
INJECT_CONFIGS=(
  ".claude/settings.json"
  ".claude/settings.local.json"
  ".gemini/settings.json"
  ".cursor/settings.json"
)

# Extract a TOP-LEVEL string field from a JSON file. A naive /"name"\s*:\s*"..."/
# grabs the FIRST occurrence anywhere, so a hostile package.json that puts e.g.
# "author":{"name":"innocent"} before its real top-level "name" shadows the real
# value and evades attribution. This walks the JSON tracking brace/bracket depth
# and only returns the value of a key found at depth 1 (the root object). It does
# not execute anything in the file.
json_string_field() {
  local field="$1" file="$2"
  perl -e '
    my $f = shift @ARGV;
    local $/; my $s = <>;
    return unless defined $s;
    my $len = length $s; my $i = 0; my $depth = 0;
    while ($i < $len) {
      my $c = substr($s,$i,1);
      if ($c eq "\"") {
        my $j = $i+1; my $key = "";
        while ($j < $len) {
          my $d = substr($s,$j,1);
          if ($d eq "\\") { $key .= substr($s,$j+1,1); $j+=2; next; }
          last if $d eq "\"";
          $key .= $d; $j++;
        }
        my $here = $depth; $i = $j+1;
        if ($here == 1) {
          my $k = $i; $k++ while $k < $len && substr($s,$k,1) =~ /\s/;
          if ($k < $len && substr($s,$k,1) eq ":") {
            my $v = $k+1; $v++ while $v < $len && substr($s,$v,1) =~ /\s/;
            if ($v < $len && substr($s,$v,1) eq "\"") {
              my $m = $v+1; my $vv = "";
              while ($m < $len) {
                my $d = substr($s,$m,1);
                if ($d eq "\\") { $vv .= substr($s,$m+1,1); $m+=2; next; }
                last if $d eq "\"";
                $vv .= $d; $m++;
              }
              if ($key eq $f) { print $vv; exit 0; }
            }
          }
        }
        next;
      }
      if ($c eq "{" || $c eq "[") { $depth++; $i++; next; }
      if ($c eq "}" || $c eq "]") { $depth--; $i++; next; }
      $i++;
    }
  ' "$field" "$file" 2>/dev/null
}

known_bad_exact() {
  local needle="$1@$2" i
  for i in "${KNOWN_BAD_PACKAGES[@]}"; do
    [ "$i" = "$needle" ] && return 0
  done
  return 1
}

# Comma-join the advisory-recorded bad versions for an exact package name, so a
# watchlist REVIEW shows what to compare against without opening the advisory.
# Empty output = scope is on the watchlist but this package has no pinned entry.
known_bad_versions_for() {
  local name="$1" i out=""
  for i in "${KNOWN_BAD_PACKAGES[@]}"; do
    case "$i" in
      "$name@"*) out="${out:+$out, }${i##*@}" ;;
    esac
  done
  printf '%s' "$out"
}

# "N known-bad version(s) across M package(s)" for a watch scope, derived from
# KNOWN_BAD_PACKAGES (which groups a package's versions consecutively) -- used
# by the lockfile scope backstop REVIEW.
scope_known_bad_summary() {
  local scope="$1" i nv=0 np=0 last=""
  for i in "${KNOWN_BAD_PACKAGES[@]}"; do
    case "$i" in
      "$scope"/*)
        nv=$((nv+1))
        if [ "${i%@*}" != "$last" ]; then np=$((np+1)); last="${i%@*}"; fi ;;
    esac
  done
  if [ "$nv" -gt 0 ]; then
    printf '%d known-bad version(s) across %d package(s)' "$nv" "$np"
  else
    printf 'no version-pinned entries; verify against advisory'
  fi
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
  # @redhat-cloud-services intentionally absent -- it is a HIT scope (see WATCH_RE
  # note), caught earlier by prefix_hit_pkg, so it never reaches this branch.
  case "$1" in
    @tanstack/*|@uipath/*|@mistralai/*|@opensearch-project/*|@antv/*|@squawk/*) return 0 ;;
  esac
  return 1
}

report_package_reference() {
  local name="$1" version="$2" where="$3" kbv
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
    kbv="$(known_bad_versions_for "$name")"
    if [ -n "$kbv" ]; then
      kbv="known-bad: $kbv"
    else
      kbv="no advisory-pinned versions for this package"
    fi
    if [ -n "$version" ]; then
      review "watchlist package present (verify exact version vs advisory): $name@$version in $where ($kbv)"
    else
      review "watchlist package present (verify exact version vs advisory): $name in $where ($kbv)"
    fi
  fi
}

# Emit "name<TAB>resolved-version" for every package in a lockfile, across the
# npm/yarn/pnpm formats. CRITICAL: for yarn and yarn-berry the entry KEY carries a
# semver RANGE (e.g. @x/y@^1.2.3), not the resolved version -- pairing the key's
# range against an exact known-bad list silently misses everything, so we read the
# resolved value off the block's own "version"/"resolution" line. Spurious pairs
# are harmless: report_package_reference only acts on known-bad/prefix/watch names.
scan_lock_pairs() {
  local lock="$1"
  # \x27 is a single quote (the whole perl program is single-quoted for the shell).
  perl -0777 -ne '
    # npm package-lock v2/v3: "node_modules/<name>": { ... "version": "x.y.z" }
    while (/"node_modules\/((?:@[^\/"]+\/)?[^\/"]+)"\s*:\s*\{.*?"version"\s*:\s*"([^"]+)"/sg) {
      print "$1\t$2\n";
    }
    # npm package-lock v1 (and nested deps): "<name>": { "version": "x.y.z" ... }
    while (/"((?:@[^"\/]+\/)?[^"\/@]+)"\s*:\s*\{\s*"version"\s*:\s*"([^"]+)"/g) {
      print "$1\t$2\n";
    }
    # yarn classic AND yarn-berry: the key line carries the range; the resolved
    # version is the block-local "version" line (classic: version "x"; berry:
    # version: x). Capture the name from the key, the version from the block.
    while (/^[ \t]*"?((?:@[^\/\s"]+\/)?[^@\s",]+)@[^\n:]*:[ \t]*\r?\n(?:[^\n]*\n)*?[ \t]+version:?[ \t]+"?([^"\s]+)"?/mg) {
      print "$1\t$2\n";
    }
    # pnpm v6-v8: "  /<name>@<version>:"  (leading slash; optional (peer) suffix)
    while (/^[ \t]{2,}\/((?:@[^\/\s:]+\/)?[^@\s:]+)@([^:\s(]+)[:(]/mg) {
      print "$1\t$2\n";
    }
    # pnpm v9: "  \x27<name>@<version>\x27:"  (quoted, NO leading slash)
    while (/^[ \t]+\x27((?:@[^\/\s\x27]+\/)?[^@\s\x27]+)@([^\x27\s(]+)\x27:/mg) {
      print "$1\t$2\n";
    }
    # yarn-berry resolution lines: resolution: "<name>@npm:<version>"
    while (/resolution:\s*"((?:@[^\/"]+\/)?[^@"]+)@(?:npm:)?([^"(]+?)(?:\([^"]*\))?"/g) {
      print "$1\t$2\n";
    }
  ' "$lock" 2>/dev/null
}

run_npm_checks() {
  local ROOT="$1"
  local package_hits=0 projects_found=0 binding_gyp_hits=0 gyp_total=0
  local pkgjson dir modpkg name version lock bg pkgdir rootidx bad nonidiom sz rel base f cfg d task

  section "npm: affected package families (installed trees)"
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

  section "npm: Phantom Gyp payload in node_modules (weaponized binding.gyp)"
  # Wave-2 vector: a 157-byte binding.gyp triggers 'node-gyp rebuild' on install,
  # weaponizing gyp command substitution to run a dropped SCRIPT FILE:
  #   "<!(node index.js > /dev/null 2>&1 && echo stub.c)"
  # NOTE: binding.gyp is a NORMAL file for native modules (better-sqlite3,
  # node-pty, keytar, ...), and the idiom "<!(node -p \"require('node-addon-api')
  # .include_dir\")" is legitimate -- that runs node -p on an EXPRESSION, not a
  # .js file. See AGENTS.md FP rule 1.
  while IFS= read -r -d '' bg; do
    gyp_total=$((gyp_total+1))
    pkgdir="$(dirname "$bg")"
    rootidx="$pkgdir/index.js"
    bad=0
    if [ -f "$rootidx" ] && grep -Eq "$PAYLOAD_MARKERS" "$rootidx" 2>/dev/null; then
      bad=1; hit "payload code marker in root index.js beside binding.gyp: $rootidx"
      grep -noE "$PAYLOAD_MARKERS" "$rootidx" 2>/dev/null | sort -u | sed 's/^/    /' | head -n 5
    elif grep -Eq '<!@?\(\s*(node|bun)\b' "$bg" 2>/dev/null; then
      nonidiom="$(grep -noE '<!@?\([^)]*' "$bg" 2>/dev/null \
        | grep -E '<!@?\(\s*(node|bun)\b' \
        | grep -vE '\(\s*(node|bun)\b[[:space:]]+(-p|--print|-e|--eval)\b')"
      if [ -n "$nonidiom" ]; then
        if printf '%s\n' "$nonidiom" | grep -Eq '\.[mc]?js\b'; then
          bad=1
          hit "binding.gyp runs a .js via command substitution (not node -p idiom): $bg"
        else
          review "binding.gyp runs node/bun via command substitution without the -p/-e idiom (verify): $bg"
        fi
        printf '%s\n' "$nonidiom" | sed 's/^/    /' | head -n 5
        if [ -f "$rootidx" ]; then
          sz="$(wc -c < "$rootidx" 2>/dev/null | tr -d ' ')"
          [ -n "${sz:-}" ] && info "    (root index.js is ${sz} bytes)"
        fi
      fi
    fi
    binding_gyp_hits=$((binding_gyp_hits+bad))
  done < <(find "$ROOT" -path '*/node_modules/*/binding.gyp' -print0 2>/dev/null)
  info "$gyp_total binding.gyp file(s) seen; $binding_gyp_hits weaponized"

  section "npm: affected packages referenced in lockfiles"
  while IFS= read -r -d '' lock; do
    while IFS="$(printf '\t')" read -r name version; do
      report_package_reference "$name" "$version" "$lock"
    done < <(scan_lock_pairs "$lock")

    if grep -Eq "$PKG_RE" "$lock" 2>/dev/null; then
      hit "affected package reference in $lock"
      grep -nE "$PKG_RE" "$lock" 2>/dev/null | sed 's/^/    /' | head -n 40
    fi
    if grep -Eq "$WATCH_RE" "$lock" 2>/dev/null; then
      local scopes scope
      scopes="$(grep -oE "$WATCH_RE" "$lock" 2>/dev/null | sort -u | paste -sd' ' -)"
      review "watchlist scope(s) present (legit libs; verify versions vs advisory): $lock"
      for scope in $scopes; do
        info "      $scope: $(scope_known_bad_summary "$scope") -- per-package detail above"
      done
    fi
  done < <(find "$ROOT" \
    \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    \( -name package-lock.json -o -name npm-shrinkwrap.json -o -name yarn.lock -o -name pnpm-lock.yaml \) \
    -print0 2>/dev/null)

  section "npm: injected AI-assistant / editor backdoor files"
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

  section "npm: Claude Code / OpenCode persistence (SessionStart hooks)"
  local agent_config_files=(
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

  section "npm: VS Code task persistence (folderOpen auto-run)"
  while IFS= read -r -d '' task; do
    if grep -Eq 'folderOpen' "$task" 2>/dev/null; then
      hit "folderOpen task persistence: $task"
      grep -nE 'folderOpen|setup\.mjs|bun' "$task" 2>/dev/null | sed 's/^/    /'
    fi
  done < <(find "$ROOT" \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    -path '*/.vscode/tasks.json' -print0 2>/dev/null)

  section "npm: payload code markers in source / config trees"
  while IFS= read -r -d '' f; do
    if grep -Eq "$PAYLOAD_MARKERS|$IOC_RE" "$f" 2>/dev/null; then
      hit "payload/IOC marker: $f"
      grep -nE "$PAYLOAD_MARKERS|$IOC_RE" "$f" 2>/dev/null | sed 's/^/    /' | head -n 5
    fi
  done < <(find "$ROOT" \
    \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name 'binding.gyp' \) \
    -print0 2>/dev/null)
}
