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

# Families, exact bad versions, watch scopes, the PKG_RE / WATCH_RE sweeps
# derived from them, and the shared classifier all live in lib/policy.sh.

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

# The shared ladder (lib/policy.sh) with the npm policy predicates bound to it.
# The classification is RETURNED: run_npm_checks owns package_hits.
report_package_reference() { # name version where
  policy_report_package known_bad_exact prefix_hit_pkg watch_pkg known_bad_versions_for ' family' "$@"
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
    report_package_reference "$name" "$version" "$modpkg" && package_hits=$((package_hits+1))
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
      report_package_reference "$name" "$version" "$lock" && package_hits=$((package_hits+1))
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
