# shellcheck shell=bash
# ============================================================================
# pkg-ioc :: lib/policy.sh
#
# THE canonical IOC policy representation: every affected-package family, watch
# scope/name and advisory-pinned name@version is declared here exactly once, and
# the text sweeps (PKG_RE, WATCH_RE, PYPI_HIT_BOUND, PYPI_WATCH_BOUND) plus
# watch_pkg() are DERIVED from them at source time -- one policy, one
# representation. Sourced by scan.sh after common.sh (it reports via
# hit()/review()) and before the ecosystem modules, which keep their parser
# specifics and cite the advisories behind every indicator below.
# ============================================================================

# --- Derivation helpers (fork-free; each assigns to the variable NAMED by $1) --
# `@` and `/` are NOT ERE metacharacters -- escaping them is undefined in POSIX
# ERE and would change the matcher text -- so they stay bare.
policy_ere_escape() { # varname literal
  local __v="$1" s="$2" out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in '.'|'['|']'|'('|')'|'{'|'}'|'*'|'+'|'?'|'|'|'^'|'$'|\\) c="\\$c" ;; esac
    out="$out$c"
  done
  printf -v "$__v" '%s' "$out"
}

# Style `plain` = unanchored alternation (the npm sweeps: a lockfile naming
# "autotelic" matches the "autotel" family sweep, unlike the parsed-name
# classifier below); `pypi` adds PEP 503 `-`/`_` interchange and name-character
# boundaries, so the REAL langchain-core / openai / requests / flask never match.
policy_derive_matcher() { # varname style name...
  local __v="$1" style="$2" acc="" e n; shift 2
  for n in "$@"; do
    policy_ere_escape e "$n"
    [ "$style" = pypi ] && e="${e//-/[-_]}"
    acc="${acc:+$acc|}$e"
  done
  [ "$style" = pypi ] && acc="(^|[^A-Za-z0-9._-])($acc)([^A-Za-z0-9._-]|\$)"
  printf -v "$__v" '%s' "$acc"
}

# --- npm policy data --------------------------------------------------------
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

# Broad, LEGITIMATE scopes where only specific versions were compromised
# (mini-Shai-Hulud / CVE-2026-45321 for @tanstack). Widely-used libraries, so
# presence is NOT proof of compromise -- a REVIEW watchlist. @redhat-cloud-services
# is deliberately NOT here (see AGENTS.md FP rule 2): it is a HIT scope. Both the
# WATCH_RE lockfile sweep and watch_pkg() derive from this one list.
WATCH_SCOPES=("@tanstack" "@uipath" "@mistralai" "@opensearch-project" "@antv" "@squawk")

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

# --- PyPI policy data -------------------------------------------------------
# Attacker-specific / lookalike / typosquat names (PEP 503 normalized). A name
# match alone is high-signal -> HIT. These are NOT real established packages.
PYPI_HIT_NAMES=(
  dreamgen
  instructor-mcp
  langchain-core-mcp
  mem8
  mflux-streamlit
  openai-mcp
  orchestr8-platform
  ray-mcp-server
  tiktoken-mcp
  rsquests           # typosquat of requests
  tlask              # typosquat of flask
  rlask              # typosquat of flask
)

# REAL bioinformatics packages where only SPECIFIC versions were poisoned. Name
# alone is a false-positive cannon (these are legitimately installed in research
# environments), so name-only = REVIEW; the exact bad version = HIT via
# PYPI_KNOWN_BAD. The PyPI edition of the @tanstack watchlist lesson.
PYPI_WATCH_NAMES=(
  embiggen
  ensmallen
  gpsea
  phenopacket-store-toolkit
  ppkt2synergy
  pyphetools
)

# Advisory-backed exact name@version (PEP 503 normalized name). Every entry
# traces to the Socket.dev IOC list.
PYPI_KNOWN_BAD=(
  "dreamgen@1.8.1"
  "embiggen@0.11.97"
  "ensmallen@0.8.101"
  "gpsea@0.9.14"
  "instructor-mcp@1.15.2" "instructor-mcp@1.15.3"
  "langchain-core-mcp@1.4.2" "langchain-core-mcp@1.4.3"
  "mem8@6.0.1"
  "mflux-streamlit@0.0.3" "mflux-streamlit@0.0.4"
  "openai-mcp@2.41.1" "openai-mcp@2.41.2"
  "orchestr8-platform@3.3.2"
  "phenopacket-store-toolkit@0.1.7"
  "ppkt2synergy@0.1.1"
  "pyphetools@0.9.120"
  "ray-mcp-server@0.2.1"
  "rlask@3.1.7"
  "rsquests@2.34.3"
  "tiktoken-mcp@0.13.1" "tiktoken-mcp@0.13.2"
  "tlask@3.1.4"
)

# --- Derived matchers (never hand-written; semantics of the retired literals) --
policy_derive_matcher PKG_RE plain "${PKG_PREFIXES[@]}"
policy_derive_matcher WATCH_RE plain "${WATCH_SCOPES[@]}"
policy_derive_matcher PYPI_HIT_BOUND pypi "${PYPI_HIT_NAMES[@]}"
policy_derive_matcher PYPI_WATCH_BOUND pypi "${PYPI_WATCH_NAMES[@]}"

# --- Policy predicates ------------------------------------------------------
# One membership test over a canonical array, in three styles:
#   exact   whole-string equality (an exact "name@version" needle is just a
#           longer name; PyPI names are compared PEP 503 normalized),
#   family  the name, a scope member or a hyphenated sibling -- but NOT an
#           arbitrary longer word ("autotelic" is not "autotel"),
#   scope   a package INSIDE the scope; the bare scope is not a package.
policy_match() { # name style candidate...
  local n="$1" style="$2" c; shift 2
  for c in "$@"; do
    case "$style" in
      exact)  [ "$c" = "$n" ] && return 0 ;;
      family) case "$n" in "$c"|"$c"/*|"$c"-*) return 0 ;; esac ;;
      scope)  case "$n" in "$c"/*) return 0 ;; esac ;;
    esac
  done
  return 1
}

# Comma-join the advisory-recorded bad versions for an exact package name so a
# watchlist REVIEW shows what to compare against; empty = no pinned entry.
policy_known_bad_versions() { # name entry...
  local name="$1" i out=""; shift
  for i in "$@"; do case "$i" in "$name@"*) out="${out:+$out, }${i##*@}" ;; esac; done
  printf '%s' "$out"
}

known_bad_exact() { policy_match "$1@$2" exact "${KNOWN_BAD_PACKAGES[@]}"; }
known_bad_versions_for() { policy_known_bad_versions "$1" "${KNOWN_BAD_PACKAGES[@]}"; }
prefix_hit_pkg() { policy_match "$1" family "${PKG_PREFIXES[@]}"; }
# @redhat-cloud-services is absent from WATCH_SCOPES on purpose (AGENTS.md FP rule 2).
watch_pkg() { policy_match "$1" scope "${WATCH_SCOPES[@]}"; }
pypi_known_bad_exact() { policy_match "$1@$2" exact "${PYPI_KNOWN_BAD[@]}"; }
pypi_known_bad_versions_for() { policy_known_bad_versions "$1" "${PYPI_KNOWN_BAD[@]}"; }
pypi_hit_name() { policy_match "$1" exact "${PYPI_HIT_NAMES[@]}"; }
pypi_watch_name() { policy_match "$1" exact "${PYPI_WATCH_NAMES[@]}"; }

# "N known-bad version(s) across M package(s)" for a watch scope, derived from
# KNOWN_BAD_PACKAGES (which groups a package's versions consecutively) -- used by
# the lockfile scope backstop REVIEW.
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

# --- Classification ---------------------------------------------------------
# One ladder for every ecosystem -- an advisory-pinned exact name@version, then
# a family/name match, then the watchlist, then nothing -- each ecosystem
# injecting its own predicates over its own arrays. The classification is an
# explicit RESULT: returned, never written into the caller's variables. These
# helpers used to increment a `package_hits` that was `local` to run_*_checks and
# reachable only through bash dynamic scope; the counter's owner now does it.
POLICY_CLASS_MATCH=0   # affected package (exact version or family) -> HIT, counts
POLICY_CLASS_WATCH=1   # watchlist scope or name -> REVIEW, never counts
POLICY_CLASS_NONE=2    # no policy match -> silent

# `noun` follows "affected package" in the family HIT (" family" for npm's prefix
# families, empty for PyPI names); the `(known-bad: ...)` suffix is what makes a
# watchlist REVIEW actionable (AGENTS.md FN rule 9).
policy_report_package() { # exact_fn family_fn watch_fn versions_fn noun name version where
  local noun="$5" name="$6" version="$7" where="$8" kbv
  [ -n "$name" ] || return "$POLICY_CLASS_NONE"
  if [ -n "$version" ] && "$1" "$name" "$version"; then
    hit "known malicious package version $name@$version in $where"
    return "$POLICY_CLASS_MATCH"
  fi
  if "$2" "$name"; then
    hit "affected package$noun '$name'${version:+@$version} present in $where"
    return "$POLICY_CLASS_MATCH"
  fi
  if "$3" "$name"; then
    kbv="$("$4" "$name")"
    kbv="${kbv:+known-bad: $kbv}"
    review "watchlist package present (verify exact version vs advisory): $name${version:+@$version} in $where (${kbv:-no advisory-pinned versions for this package})"
    return "$POLICY_CLASS_WATCH"
  fi
  return "$POLICY_CLASS_NONE"
}
