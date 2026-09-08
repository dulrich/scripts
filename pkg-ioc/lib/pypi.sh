# shellcheck shell=bash
# ============================================================================
# pkg-ioc :: lib/pypi.sh
#
# PyPI / "Hades" leg of the Shai-Hulud / Miasma campaign. Sourced by scan.sh;
# exposes run_pypi_checks "<root>". Detection-only and read-only.
#
# Three delivery branches are detected (see AGENTS.md): a `*-setup.pth` startup
# hook with a bundled `_index.js`; a trojanized native `.abi3.so` running
# `_index.js` at import; and the `langchain-core-mcp` split loader, whose `.pth`
# searches `sys.path` for an `_index.js` it does not bundle.
#
# Indicator provenance (PyPI leg):
#   - Socket.dev, "Mini Shai-Hulud, Miasma, and Hades Worms Target Bioinformatics
#     and MCP Developers via Malicious PyPI Wheels" (2026-06-08), and "Shai-Hulud
#     Descends to Hades: Miasma Worm Campaign Spreads with New PyPI Wave"
# ============================================================================

# HIT names, watch names, exact bad name@versions and the PYPI_*_BOUND sweeps
# derived from them all live in lib/policy.sh.

# Known malicious artifact SHA-256 hashes (Socket.dev "Notable Hashes").
PYPI_KNOWN_HASHES=(
  "6d332f814f15f19758d65026bbfd0a8c49671b319ec77b8fa1b27fc48afff7d9  langchain_core_mcp-1.4.2-py3-none-any.whl"
  "6506d31707a39949f89534bf9705bcf889f1ecae3dbc6f4ff88d67a8be3d01b2  langchain_core-setup.pth"
)

# Trojanized native extensions reported in the bioinformatics subcluster. Bare
# .abi3.so is normal (numpy, cryptography, ...), so only these exact filenames --
# or an .abi3.so co-located with _index.js -- are flagged (rule B).
PYPI_KNOWN_SO=("ensmallen_haswell.abi3.so" "ensmallen_core2.abi3.so")

# Legit *executable* .pth files (they begin with an `import` line by design) are
# allowlisted by basename in pypi_check_pth_hooks so a clean env stays quiet:
# __editable__*, _virtualenv.pth, distutils-precedence.pth, easy-install.pth.

# PEP 503 name normalization: lowercase, collapse any run of . _ - to a single -.
normalize_pypi_name() {
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '._-' '-')"
  n="${n#-}"; n="${n%-}"
  printf '%s' "$n"
}

# The same shared ladder as the npm leg, behind PEP 503 normalization (rule D).
# The classification is RETURNED: the calling check owns pypi_package_hits.
report_pypi_package() { # name version where
  local nname; nname="$(normalize_pypi_name "$1")"
  [ -n "$nname" ] || return "$POLICY_CLASS_NONE"
  policy_report_package pypi_known_bad_exact pypi_hit_name pypi_watch_name pypi_known_bad_versions_for '' "$nname" "$2" "$3"
}

# Emit "name<TAB>version" pairs across PyPI manifest/lock formats. Spurious pairs
# are harmless: report_pypi_package only acts on known names. \x27 is a single
# quote (the whole perl program is single-quoted for the shell).
scan_pyreq_pairs() {
  local f="$1"
  perl -0777 -ne '
    # requirements.txt / pyproject pinned deps: name==version (also extras/markers)
    while (/([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^\]]*\])?\s*==\s*([0-9][^\s,;"\x27)\]]*)/g) { print "$1\t$2\n"; }
    # TOML lock (poetry / pdm / uv): name = "X" then a later version = "Y"
    while (/name\s*=\s*"([^"]+)"\s*\r?\n(?:[^\n]*\n)*?\s*version\s*=\s*"([^"]+)"/g) { print "$1\t$2\n"; }
    # Pipfile.lock JSON: "name": { ... "version": "==X" }
    while (/"([A-Za-z0-9][A-Za-z0-9._-]*)"\s*:\s*\{[^{}]*?"version"\s*:\s*"==?([^"\s]+)"/g) { print "$1\t$2\n"; }
    # conda environment.yml list pins: "- name=1.2.3" or "- name=1.2.3=build"
    # (single =; the digit guard keeps pip == pins from double-matching here).
    while (/^\s*-\s*([A-Za-z0-9][A-Za-z0-9._-]*)=([0-9][^\s=,;"\x27]*)(?:=\S+)?\s*$/mg) { print "$1\t$2\n"; }
  ' "$f" 2>/dev/null
}

pypi_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  fi
}

pypi_check_installed_dists() {
  local m name version dist_count=0 pypi_package_hits=0
  section "pypi: affected packages (installed distributions)"
  while IFS= read -r -d '' m; do
    dist_count=$((dist_count+1))
    name="$(grep -m1 -iE '^Name:' "$m" 2>/dev/null | sed -E 's/^[Nn]ame:[[:space:]]*//; s/[[:space:]]*$//')"
    version="$(grep -m1 -iE '^Version:' "$m" 2>/dev/null | sed -E 's/^[Vv]ersion:[[:space:]]*//; s/[[:space:]]*$//')"
    report_pypi_package "$name" "$version" "$m" && pypi_package_hits=$((pypi_package_hits+1))
  done < <(inventory_root | inventory_select file '*.dist-info/METADATA' '*.egg-info/PKG-INFO')
  info "$dist_count installed distribution(s) scanned"
  info "$pypi_package_hits affected-package match(es) found"
}

pypi_check_manifests() {
  local f name version wn wn_re
  section "pypi: affected packages referenced in dependency manifests"
  while IFS= read -r -d '' f; do
    while IFS="$(printf '\t')" read -r name version; do
      report_pypi_package "$name" "$version" "$f"
    done < <(scan_pyreq_pairs "$f")
    report_markers hit "affected package reference in $f" "$f" "$PYPI_HIT_BOUND" 40 icase
    grep -qiE "$PYPI_WATCH_BOUND" "$f" 2>/dev/null || continue
    review "watchlist (bioinformatics) package referenced (verify exact version vs advisory): $f"
    show_matches "$f" "$PYPI_WATCH_BOUND" 20 icase
    for wn in "${PYPI_WATCH_NAMES[@]}"; do
      policy_derive_matcher wn_re pypi "$wn"
      grep -qiE "$wn_re" "$f" 2>/dev/null \
        && info "      $wn known-bad: $(pypi_known_bad_versions_for "$wn")"
    done
  done < <(inventory_root | inventory_select file 'requirements*.txt' 'pyproject.toml' 'poetry.lock' \
    'Pipfile' 'Pipfile.lock' 'pdm.lock' 'uv.lock' 'environment.yml' 'environment.yaml')
}

pypi_check_pth_hooks() {
  local pth base pth_total=0 marker
  section "pypi: executable .pth startup hooks"
  # NOTE: .pth files are NORMAL in site-packages; most are plain path lines and a
  # few legit ones (__editable__*, _virtualenv.pth, ...) begin with an import line.
  # Flag on the Hades loader signature, never on existence (AGENTS.md rule A).
  while IFS= read -r -d '' pth; do
    pth_total=$((pth_total+1))
    base="$(basename "$pth")"
    case "$base" in __editable__*|_virtualenv.pth|distutils-precedence.pth|easy-install.pth) continue ;; esac
    # Python only executes .pth lines that start with `import`.
    grep -qE '^[[:space:]]*import[[:space:]]' "$pth" 2>/dev/null || continue
    marker="$(grep -nE "_index\.js|\.bun_ran|oven-sh/bun|getBunPath|sys\.path|subprocess|urllib|$IOC_RE" "$pth" 2>/dev/null | head -n 8)"
    case "$base" in
      *-setup.pth)
        hit "Hades-style executable startup hook (*-setup.pth): $pth"
        [ -n "$marker" ] && printf '%s\n' "$marker" | sed 's/^/    /' ;;
      *)
        if [ -n "$marker" ]; then
          hit "executable .pth with payload-loader markers: $pth"
          printf '%s\n' "$marker" | sed 's/^/    /'
        else
          review "executable .pth (begins with import; verify it is an editable install you created): $pth"
        fi ;;
    esac
  done < <(inventory_root | inventory_select file '*.pth')
  info "$pth_total .pth file(s) seen"
}

pypi_check_staged_payload() {
  local idx idx_total=0
  section "pypi: staged JavaScript stealer payload (_index.js)"
  # WARNING: the malicious _index.js opens with a fake prompt-injection comment
  # header crafted to derail LLM-assisted triage (rule E). Do NOT paste it into an
  # AI assistant -- this greps byte markers only, and never prints the file body.
  info "do not paste any flagged _index.js into an AI assistant (anti-analysis header)"
  while IFS= read -r -d '' idx; do
    idx_total=$((idx_total+1))
    if ! report_markers hit "Hades stealer payload markers in _index.js: $idx" "$idx" "$PAYLOAD_MARKERS|$IOC_RE" 5; then
      case "$idx" in
        */site-packages/*|*/dist-packages/*)
          review "bare _index.js inside a Python env (possible split-loader payload): $idx" ;;
        *)
          # P3: a one-shot, depth-1 sibling probe of this file's own directory.
          if find "$(dirname "$idx")" -maxdepth 1 \( -name '*.pth' -o -name '*.abi3.so' -o -name '*.dist-info' \) -print -quit 2>/dev/null | grep -q .; then
            review "bare _index.js co-located with Python install artifacts: $idx"
          fi ;;
      esac
    fi
  done < <(inventory_root | inventory_select file '_index.js')
  info "$idx_total _index.js file(s) seen"
}

pypi_check_native_extensions() {
  local so so_total=0 sobase known kname
  section "pypi: trojanized native extensions (.abi3.so)"
  while IFS= read -r -d '' so; do
    so_total=$((so_total+1))
    sobase="$(basename "$so")"
    known=0
    for kname in "${PYPI_KNOWN_SO[@]}"; do [ "$sobase" = "$kname" ] && known=1 && break; done
    if [ "$known" -eq 1 ]; then
      hit "known trojanized native extension: $so"
    elif [ -f "$(dirname "$so")/_index.js" ]; then
      review "native extension co-located with _index.js (import-time loader pattern): $so"
    fi
  done < <(inventory_root | inventory_select file '*.abi3.so')
  info "$so_total .abi3.so file(s) seen (bare extensions are normal; only known/co-located flagged)"
}

pypi_check_known_hashes() {
  local artifact h known kh
  section "pypi: known malicious file hashes"
  while IFS= read -r -d '' artifact; do
    h="$(pypi_sha256 "$artifact")"
    [ -n "$h" ] || continue
    for known in "${PYPI_KNOWN_HASHES[@]}"; do
      kh="${known%% *}"
      [ "$h" = "$kh" ] && hit "file matches known malicious artifact hash ($kh): $artifact"
    done
  done < <(inventory_root | inventory_select file 'langchain_core_mcp-*.whl' '*-setup.pth')
}

pypi_check_temp_artifacts() {
  section "pypi: temp artifacts (Bun run-once marker, SSH propagation)"
  local tmp_seen=0 t troot
  for troot in "${TMP_ROOTS[@]}"; do
    for t in "$troot/.bun_ran" "$troot/.sshu-setup.js"; do
      [ -e "$t" ] || continue
      tmp_seen=1
      hit "Hades temp artifact present: $t"
    done
  done
  [ "$tmp_seen" -eq 0 ] && info "no Hades temp artifacts found"
}

run_pypi_checks() {
  pypi_check_installed_dists
  pypi_check_manifests
  pypi_check_pth_hooks
  pypi_check_staged_payload
  pypi_check_native_extensions
  pypi_check_known_hashes
  pypi_check_temp_artifacts
}
