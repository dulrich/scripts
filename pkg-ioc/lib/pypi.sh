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
# Boundary-anchored regex form for manifest text sweeps (-/_ interchangeable).
PYPI_HIT_BOUND='(^|[^A-Za-z0-9._-])(dreamgen|instructor[-_]mcp|langchain[-_]core[-_]mcp|mem8|mflux[-_]streamlit|openai[-_]mcp|orchestr8[-_]platform|ray[-_]mcp[-_]server|tiktoken[-_]mcp|rsquests|tlask|rlask)([^A-Za-z0-9._-]|$)'

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
PYPI_WATCH_BOUND='(^|[^A-Za-z0-9._-])(embiggen|ensmallen|gpsea|phenopacket[-_]store[-_]toolkit|ppkt2synergy|pyphetools)([^A-Za-z0-9._-]|$)'

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

pypi_known_bad_exact() {
  local needle="$1@$2" i
  for i in "${PYPI_KNOWN_BAD[@]}"; do
    [ "$i" = "$needle" ] && return 0
  done
  return 1
}

# Comma-join the advisory-recorded bad versions for a (PEP 503 normalized)
# name, so a watchlist REVIEW shows what to compare against on the spot.
pypi_known_bad_versions_for() {
  local name="$1" i out=""
  for i in "${PYPI_KNOWN_BAD[@]}"; do
    case "$i" in
      "$name@"*) out="${out:+$out, }${i#*@}" ;;
    esac
  done
  printf '%s' "$out"
}

pypi_hit_name() {
  local n="$1" i
  for i in "${PYPI_HIT_NAMES[@]}"; do
    [ "$i" = "$n" ] && return 0
  done
  return 1
}

pypi_watch_name() {
  local n="$1" i
  for i in "${PYPI_WATCH_NAMES[@]}"; do
    [ "$i" = "$n" ] && return 0
  done
  return 1
}

report_pypi_package() {
  local name version where nname
  name="$1"; version="$2"; where="$3"
  [ -n "$name" ] || return 0
  nname="$(normalize_pypi_name "$name")"
  [ -n "$nname" ] || return 0

  if [ -n "$version" ] && pypi_known_bad_exact "$nname" "$version"; then
    pypi_package_hits=$((pypi_package_hits+1))
    hit "known malicious package version $nname@$version in $where"
  elif pypi_hit_name "$nname"; then
    pypi_package_hits=$((pypi_package_hits+1))
    if [ -n "$version" ]; then
      hit "affected package '$nname'@$version present in $where"
    else
      hit "affected package '$nname' present in $where"
    fi
  elif pypi_watch_name "$nname"; then
    local kbv
    kbv="$(pypi_known_bad_versions_for "$nname")"
    if [ -n "$kbv" ]; then
      kbv="known-bad: $kbv"
    else
      kbv="no advisory-pinned versions for this package"
    fi
    if [ -n "$version" ]; then
      review "watchlist package present (verify exact version vs advisory): $nname@$version in $where ($kbv)"
    else
      review "watchlist package present (verify exact version vs advisory): $nname in $where ($kbv)"
    fi
  fi
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
  local f wn pth base pth_total=0 has_import marker
  local idx idx_total=0 idxdir
  local so so_total=0 sobase
  local h known kh kname
  local artifact

  section "pypi: affected packages (installed distributions)"
  while IFS= read -r -d '' m; do
    dist_count=$((dist_count+1))
    name="$(grep -m1 -iE '^Name:' "$m" 2>/dev/null | sed -E 's/^[Nn]ame:[[:space:]]*//; s/[[:space:]]*$//')"
    version="$(grep -m1 -iE '^Version:' "$m" 2>/dev/null | sed -E 's/^[Vv]ersion:[[:space:]]*//; s/[[:space:]]*$//')"
    report_pypi_package "$name" "$version" "$m"
  done < <(find "$ROOT" \
    \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    -type f \( -path '*.dist-info/METADATA' -o -path '*.egg-info/PKG-INFO' \) \
    -print0 2>/dev/null)
  info "$dist_count installed distribution(s) scanned"
  info "$pypi_package_hits affected-package match(es) found"

  section "pypi: affected packages referenced in dependency manifests"
  while IFS= read -r -d '' f; do
    while IFS="$(printf '\t')" read -r name version; do
      report_pypi_package "$name" "$version" "$f"
    done < <(scan_pyreq_pairs "$f")

    if grep -qiE "$PYPI_HIT_BOUND" "$f" 2>/dev/null; then
      hit "affected package reference in $f"
      grep -niE "$PYPI_HIT_BOUND" "$f" 2>/dev/null | sed 's/^/    /' | head -n 40
    fi
    if grep -qiE "$PYPI_WATCH_BOUND" "$f" 2>/dev/null; then
      review "watchlist (bioinformatics) package referenced (verify exact version vs advisory): $f"
      grep -niE "$PYPI_WATCH_BOUND" "$f" 2>/dev/null | sed 's/^/    /' | head -n 20
      for wn in "${PYPI_WATCH_NAMES[@]}"; do
        if grep -qiE "(^|[^A-Za-z0-9._-])${wn//-/[-_]}([^A-Za-z0-9._-]|$)" "$f" 2>/dev/null; then
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
