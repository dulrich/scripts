# shellcheck shell=bash
# ============================================================================
# pkg-ioc :: lib/pypi.sh
#
# PyPI / "Hades" leg of the Shai-Hulud / Miasma campaign. Sourced by scan.sh;
# exposes run_pypi_checks "<root>". Detection-only and read-only.
#
# Three delivery branches are detected (see AGENTS.md):
#   1. `*-setup.pth` executable startup hook + bundled `_index.js`
#   2. trojanized native `.abi3.so` extension that runs `_index.js` on import
#   3. split loader (`langchain-core-mcp`): `*-setup.pth` searches sys.path for
#      an `_index.js` it does not bundle
#
# Indicator provenance (PyPI leg):
#   - Socket.dev, "Mini Shai-Hulud, Miasma, and Hades Worms Target Bioinformatics
#     and MCP Developers via Malicious PyPI Wheels" (2026-06-08)
#   - Socket.dev, "Shai-Hulud Descends to Hades: Miasma Worm Campaign Spreads
#     with New PyPI Wave" (the weekend report)
# ============================================================================

# HIT names, watch names, exact bad name@versions and the PYPI_*_BOUND sweeps
# derived from them all live in lib/policy.sh.

# Known malicious artifact SHA-256 hashes (Socket.dev "Notable Hashes").
PYPI_KNOWN_HASHES=(
  "6d332f814f15f19758d65026bbfd0a8c49671b319ec77b8fa1b27fc48afff7d9  langchain_core_mcp-1.4.2-py3-none-any.whl"
  "6506d31707a39949f89534bf9705bcf889f1ecae3dbc6f4ff88d67a8be3d01b2  langchain_core-setup.pth"
)

# Trojanized native extensions reported in the bioinformatics subcluster. Bare
# .abi3.so is a normal compiled extension (numpy, cryptography, ...), so only
# these exact filenames -- or an .abi3.so co-located with _index.js -- are flagged.
PYPI_KNOWN_SO=(
  "ensmallen_haswell.abi3.so"
  "ensmallen_core2.abi3.so"
)

# Legit *executable* .pth files (they begin with an `import` line by design)
# are allowlisted by basename in run_pypi_checks so a clean env stays quiet:
# editable installs (__editable__*), _virtualenv.pth, distutils-precedence.pth,
# easy-install.pth.

# PEP 503 name normalization: lowercase, collapse any run of . _ - to a single -.
normalize_pypi_name() {
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '._-' '-')"
  n="${n#-}"; n="${n%-}"
  printf '%s' "$n"
}

# The same shared ladder as the npm leg, behind PEP 503 normalization. The
# classification is RETURNED: run_pypi_checks owns pypi_package_hits.
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
    while (/([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^\]]*\])?\s*==\s*([0-9][^\s,;"\x27)\]]*)/g) {
      print "$1\t$2\n";
    }
    # TOML lock (poetry / pdm / uv): name = "X" then a later version = "Y"
    while (/name\s*=\s*"([^"]+)"\s*\r?\n(?:[^\n]*\n)*?\s*version\s*=\s*"([^"]+)"/g) {
      print "$1\t$2\n";
    }
    # Pipfile.lock JSON: "name": { ... "version": "==X" }
    while (/"([A-Za-z0-9][A-Za-z0-9._-]*)"\s*:\s*\{[^{}]*?"version"\s*:\s*"==?([^"\s]+)"/g) {
      print "$1\t$2\n";
    }
    # conda environment.yml list pins: "- name=1.2.3" or "- name=1.2.3=build"
    # (single =; the version-must-start-with-a-digit guard keeps pip == pins
    # from double-matching here).
    while (/^\s*-\s*([A-Za-z0-9][A-Za-z0-9._-]*)=([0-9][^\s=,;"\x27]*)(?:=\S+)?\s*$/mg) {
      print "$1\t$2\n";
    }
  ' "$f" 2>/dev/null
}

pypi_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  fi
}

run_pypi_checks() {
  local ROOT="$1"
  local pypi_package_hits=0
  local m name version dist_count=0
  local f wn wn_re pth base pth_total=0 has_import marker
  local idx idx_total=0 idxdir
  local so so_total=0 sobase
  local h known kh kname
  local artifact

  section "pypi: affected packages (installed distributions)"
  while IFS= read -r -d '' m; do
    dist_count=$((dist_count+1))
    name="$(grep -m1 -iE '^Name:' "$m" 2>/dev/null | sed -E 's/^[Nn]ame:[[:space:]]*//; s/[[:space:]]*$//')"
    version="$(grep -m1 -iE '^Version:' "$m" 2>/dev/null | sed -E 's/^[Vv]ersion:[[:space:]]*//; s/[[:space:]]*$//')"
    report_pypi_package "$name" "$version" "$m" && pypi_package_hits=$((pypi_package_hits+1))
  done < <(find "$ROOT" \
    \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    -type f \( -path '*.dist-info/METADATA' -o -path '*.egg-info/PKG-INFO' \) \
    -print0 2>/dev/null)
  info "$dist_count installed distribution(s) scanned"
  info "$pypi_package_hits affected-package match(es) found"

  section "pypi: affected packages referenced in dependency manifests"
  while IFS= read -r -d '' f; do
    while IFS="$(printf '\t')" read -r name version; do
      report_pypi_package "$name" "$version" "$f" && pypi_package_hits=$((pypi_package_hits+1))
    done < <(scan_pyreq_pairs "$f")

    if grep -qiE "$PYPI_HIT_BOUND" "$f" 2>/dev/null; then
      hit "affected package reference in $f"
      grep -niE "$PYPI_HIT_BOUND" "$f" 2>/dev/null | sed 's/^/    /' | head -n 40
    fi
    if grep -qiE "$PYPI_WATCH_BOUND" "$f" 2>/dev/null; then
      review "watchlist (bioinformatics) package referenced (verify exact version vs advisory): $f"
      grep -niE "$PYPI_WATCH_BOUND" "$f" 2>/dev/null | sed 's/^/    /' | head -n 20
      for wn in "${PYPI_WATCH_NAMES[@]}"; do
        policy_derive_matcher wn_re pypi "$wn"
        if grep -qiE "$wn_re" "$f" 2>/dev/null; then
          info "      $wn known-bad: $(pypi_known_bad_versions_for "$wn")"
        fi
      done
    fi
  done < <(find "$ROOT" \
    \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    -type f \( -name 'requirements*.txt' -o -name 'pyproject.toml' -o -name 'poetry.lock' \
      -o -name 'Pipfile' -o -name 'Pipfile.lock' -o -name 'pdm.lock' -o -name 'uv.lock' \
      -o -name 'environment.yml' -o -name 'environment.yaml' \) \
    -print0 2>/dev/null)

  section "pypi: executable .pth startup hooks"
  # NOTE: .pth files are NORMAL in site-packages; most are plain path lines, and a
  # few legit ones (__editable__*, _virtualenv.pth, ...) begin with an import line.
  # Flag on the Hades loader signature (`*-setup.pth` naming or payload markers),
  # not on existence. See AGENTS.md PyPI rule A.
  while IFS= read -r -d '' pth; do
    pth_total=$((pth_total+1))
    base="$(basename "$pth")"
    case "$base" in
      __editable__*|_virtualenv.pth|distutils-precedence.pth|easy-install.pth) continue ;;
    esac
    # Python only executes .pth lines that start with `import`.
    grep -qE '^[[:space:]]*import[[:space:]]' "$pth" 2>/dev/null && has_import=1 || has_import=0
    [ "$has_import" -eq 1 ] || continue
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
  done < <(find "$ROOT" \
    \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    -type f -name '*.pth' -print0 2>/dev/null)
  info "$pth_total .pth file(s) seen"

  section "pypi: staged JavaScript stealer payload (_index.js)"
  # WARNING: the malicious _index.js opens with a fake prompt-injection comment
  # header crafted to derail LLM-assisted triage. Do NOT paste its contents into
  # an AI assistant -- this scanner only greps byte markers and prints matched
  # lines, never the file body.
  info "do not paste any flagged _index.js into an AI assistant (anti-analysis header)"
  while IFS= read -r -d '' idx; do
    idx_total=$((idx_total+1))
    idxdir="$(dirname "$idx")"
    if grep -Eq "$PAYLOAD_MARKERS|$IOC_RE" "$idx" 2>/dev/null; then
      hit "Hades stealer payload markers in _index.js: $idx"
      grep -nE "$PAYLOAD_MARKERS|$IOC_RE" "$idx" 2>/dev/null | sed 's/^/    /' | head -n 5
    else
      case "$idx" in
        */site-packages/*|*/dist-packages/*)
          review "bare _index.js inside a Python env (possible split-loader payload): $idx" ;;
        *)
          if find "$idxdir" -maxdepth 1 \( -name '*.pth' -o -name '*.abi3.so' -o -name '*.dist-info' \) -print -quit 2>/dev/null | grep -q .; then
            review "bare _index.js co-located with Python install artifacts: $idx"
          fi ;;
      esac
    fi
  done < <(find "$ROOT" \
    \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    -type f -name '_index.js' -print0 2>/dev/null)
  info "$idx_total _index.js file(s) seen"

  section "pypi: trojanized native extensions (.abi3.so)"
  while IFS= read -r -d '' so; do
    so_total=$((so_total+1))
    sobase="$(basename "$so")"
    known=0
    for kname in "${PYPI_KNOWN_SO[@]}"; do
      [ "$sobase" = "$kname" ] && known=1 && break
    done
    if [ "$known" -eq 1 ]; then
      hit "known trojanized native extension: $so"
    elif [ -f "$(dirname "$so")/_index.js" ]; then
      review "native extension co-located with _index.js (import-time loader pattern): $so"
    fi
  done < <(find "$ROOT" \
    \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    -type f -name '*.abi3.so' -print0 2>/dev/null)
  info "$so_total .abi3.so file(s) seen (bare extensions are normal; only known/co-located flagged)"

  section "pypi: known malicious file hashes"
  while IFS= read -r -d '' artifact; do
    h="$(pypi_sha256 "$artifact")"
    [ -n "$h" ] || continue
    for known in "${PYPI_KNOWN_HASHES[@]}"; do
      kh="${known%% *}"
      if [ "$h" = "$kh" ]; then
        hit "file matches known malicious artifact hash ($kh): $artifact"
      fi
    done
  done < <(find "$ROOT" \
    \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    -type f \( -name 'langchain_core_mcp-*.whl' -o -name '*-setup.pth' \) \
    -print0 2>/dev/null)

  section "pypi: temp artifacts (Bun run-once marker, SSH propagation)"
  local tmp_seen=0 t troot
  for troot in "${TMP_ROOTS[@]}"; do
    for t in "$troot/.bun_ran" "$troot/.sshu-setup.js"; do
      if [ -e "$t" ]; then
        tmp_seen=1
        hit "Hades temp artifact present: $t"
      fi
    done
  done
  [ "$tmp_seen" -eq 0 ] && info "no Hades temp artifacts found"
}
