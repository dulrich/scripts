# AGENTS.md — pkg-ioc

Guidance for any AI agent (or human) modifying `scan.sh` or the `lib/*.sh` sub-scanners. This file is
the design contract; read it before changing detection logic. See [`README.md`](./README.md) for
user-facing docs.

## Architecture (router + sub-scanners)

`scan.sh` is a **router**, not a monolith. It parses args, prints the banner, dispatches to the
selected ecosystem sub-scanners, runs the shared host-level checks once, and prints the single
verdict + exit code. Detection logic lives in `lib/`:

- `lib/common.sh` — shared, ecosystem-agnostic machinery: the reporting helpers
  (`hr/section/hit/review/info`), `dedupe_existing_files`, the shared IOC constants (`IOC_RE`,
  `PAYLOAD_MARKERS` — same Bun-staged Hades stealer regardless of delivery vector), and
  `run_common_checks` (gh-token-monitor daemon, Bun temp artifacts, passwordless sudo, hosts-file
  redirection incl. the StepSecurity telemetry domains, zero-width agent-context injection, shell-RC
  bun download).
- `lib/npm.sh` — `run_npm_checks`: the npm leg (package families, Phantom-Gyp `binding.gyp`,
  lockfiles, injected setup files / config injection, agent + VS Code persistence, JS source sweep).
- `lib/pypi.sh` — `run_pypi_checks`: the PyPI / Hades leg (see the PyPI rules below).

**Shared-state model — source, do not exec.** The router `. "$LIBDIR/<lib>.sh"` *sources* all three
into one process so `FOUND`/`REVIEWS`/`SECTION` are shared globals and there is exactly **one**
verdict and **one** exit code. Do NOT refactor the sub-scanners into separate processes (`exec`/
subshell) — that fragments `FOUND` and forces brittle exit-code merging. The per-ecosystem counters
(`package_hits`, `pypi_package_hits`) are `local` to the `run_*` function and visible to the
report helpers via bash dynamic scope; keep them that way.

**Adding an ecosystem** (e.g. RubyGems, crates): add `lib/<eco>.sh` exposing `run_<eco>_checks
"<root>"`, source it in `scan.sh`, add an `--ecosystem` case, add fixtures to `tests/smoke.sh`. Put
anything genuinely host-level (not ecosystem-specific) in `common.sh`, not the new file.

**shellcheck must be run with `-x`** (`shellcheck -x scan.sh`) so it follows the `# shellcheck
source=` directives into the libs and analyzes them in the context that defines the shared globals.
Without `-x` it false-fails on SC1091/SC2154. The smoke harness already uses `-x`.

## Design contract

- **Detection-only and read-only.** Never revoke credentials, kill processes, stop daemons, or
  modify files. The campaign has a `gh-token-monitor` dead-man's switch that wipes `$HOME` if it
  sees its access cut, so the safe order is CHECK → ISOLATE → CLEAN → ROTATE and this tool only does
  the CHECK. "Listing only" is required even for the daemon/sudoers sections.
- **Exit contract:** `0` = clean, `2` = HIT. Only `hit()` sets `FOUND`. `review()` is informational
  and must never change the exit code — REVIEW ≠ HIT.
- **Provenance rule:** every indicator must trace to one of the advisories in `README.md`. Do not add
  an IOC you cannot cite. The scanner's header comment lists the sources.

## Fabricated indicators — do NOT reintroduce

The original web-LLM draft invented these; they appear in **no** advisory and were removed. A
regression check: `grep -nE 'ddjidd564|p2024_integrity|router_init|router_runtime|tanstack_runner|dev-env-bootstrapper' scan.sh` must return nothing.

- `ddjidd564` — fake GitHub account. The real C2 account is `liuende501` (plus a rotating pool).
- `P-2024-001`, `dev-env-bootstrapper` — invented marker/string.
- `~/.local/share/.p2024_integrity` — invented marker file. Real persistence is the
  `gh-token-monitor` daemon (systemd/launchctl).
- `router_init.js`, `router_runtime.js`, `tanstack_runner.js` — invented payload filenames. The real
  on-disk payload is a 157-byte `binding.gyp` plus an oversized obfuscated root `index.js`.

## False-positive rules (learned the hard way)

A naive version of this scanner reports COMPROMISED on essentially every clean developer machine.
These four rules keep it quiet on clean systems while still catching the real thing. Do not loosen
them without re-running the verification below.

1. **`binding.gyp` is a normal file.** Every native module ships one (`better-sqlite3`, `node-pty`,
   `keytar`, `@parcel/watcher`, …). Presence is not a finding. The *only* legitimate idiom is
   `<!(node -p "require('node-addon-api').include_dir")` — running `node`/`bun` with `-p`/`-e` on an
   inline *expression*. The malicious form executes a *file/module*:
   `<!(node index.js > /dev/null 2>&1 && echo stub.c)`. Do NOT key narrowly on `node …*.js` — that
   leaves a blind spot for a renamed payload, a no-extension entry, or a `bun` invocation. Instead:
   treat the obfuscated payload markers in the sibling root `index.js` (`getBunPath`, `aes-128-gcm`
   decipher, `oven-sh/bun` download) as the definitive HIT; any command substitution running
   `node`/`bun` that is *not* the `-p`/`-e` expression idiom is a finding — a `.js`/`.mjs`/`.cjs`
   script is a HIT, other non-idiom forms are REVIEW.
2. **Broad legit scopes are a watchlist, not a HIT.** `@tanstack`, `@uipath`, `@mistralai`, `@antv`,
   `@squawk`, `@opensearch-project` are widely-used libraries where only *specific versions* were
   compromised (CVE-2026-45321 for `@tanstack`). Matching the scope alone (`@tanstack/react-query` is
   everywhere) is a false-positive cannon — report these as REVIEW with a "verify versions" note,
   backed by the exact-version `KNOWN_BAD_PACKAGES` list for the HITs.
   Only obscure/typosquat names (`autotel`, `awaitly`, `@vapi-ai`, `ai-sdk-ollama`, `chalk-tempalte`,
   …) are safe to prefix-match as HITs.
   **Exception — `@redhat-cloud-services` is a HIT scope, not a watchlist.** Microsoft's IOC table
   states *every* package on the `@redhat-cloud-service` account was compromised, and this is a
   self-propagating worm that republishes new poisoned versions, so a static exact-version list goes
   stale. Unlike `@tanstack/react-query`, this scope is not a ubiquitous transitive dependency, so the
   FP risk of a family-prefix HIT is low. It is therefore in `PKG_PREFIXES`/`PKG_RE` (any sighting =
   HIT), with `KNOWN_BAD_PACKAGES` only supplying the precise advisory version label. Do NOT move it
   to `WATCH_RE`/`watch_pkg` — that re-opens the gap where republished redhat versions silently
   degrade to REVIEW (which does not change the exit code).
3. **Legit config files are content-checked, not existence-checked.** `.gemini/settings.json` and
   `.claude/settings.json` are normal config files the worm *injects into* — flag only on malicious
   content (`bun run`, `setup.mjs`, IOC strings). Only attacker-*invented* names (`setup.mjs`,
   `setup.mdc`, `.github/setup.js`) are flagged on existence.
4. **`if perl -ne '…'` is always true.** `perl -ne` exits `0` whether or not the pattern matched, so
   keying a finding off its exit status flags every file scanned. Capture and test the OUTPUT string
   instead. (This bug, inherited from the draft, made any machine with a `CLAUDE.md` report
   COMPROMISED.) The same "test output, not exit status" caution applies to any added `grep -q`/perl
   probes.

## False-negative / evasion rules (do NOT regress)

These close blind spots where a clean-looking change silently stops catching the real thing — the
opposite failure mode from the FP rules above, and the more dangerous one for a detection tool.

5. **Parse the *resolved* version, never the lockfile key range.** In `yarn.lock` (classic and berry)
   the entry key carries a semver *range* (`@x/y@^1.2.3`), not the installed version. Matching the key
   against the exact `KNOWN_BAD_PACKAGES` list never fires. `scan_lock_pairs` must read the version off
   the block's own `version`/`resolution` line. It must also handle all three lockfile shapes: npm
   `package-lock` v1 and v2/v3, yarn classic + berry, and pnpm v6–v8 (`/name@ver:`) *and* v9 (quoted,
   slash-less `'name@ver':`). The smoke suite carries a `package-lock.json`, a `yarn.lock`, and a
   `pnpm-lock.yaml` fixture with a known-bad version each — keep all three.
6. **`package.json` parsing must be top-level-aware.** A first-match `/"name"\s*:\s*"…"/` grabs any
   nested `"name"` (e.g. `"author":{"name":"innocent"}`), so a hostile package can shadow its real
   name and evade attribution. `json_string_field` walks brace depth and returns only depth-1 keys; do
   not replace it with a flat regex. The smoke suite has a shadowing-`name` fixture.

## PyPI (Hades leg) false-positive / false-negative rules

The PyPI leg (`lib/pypi.sh`) detects the same Bun-staged Hades stealer delivered three ways: a
`*-setup.pth` executable startup hook + bundled `_index.js`; a trojanized native `.abi3.so` that runs
`_index.js` at import time; and the `langchain-core-mcp` *split loader* whose `.pth` searches
`sys.path` for an `_index.js` it does not bundle. The same "stay quiet on clean machines" discipline
applies — these six rules are why scanning a real dev box with ~800 installed dists and dozens of
`.abi3.so`/`.pth` files yields zero false HITs.

- **A. `.pth` files are normal in site-packages.** Most are plain path lines; a few legit ones begin
  with an `import` line (`__editable__.*.pth`, `_virtualenv.pth`, `distutils-precedence.pth`,
  `easy-install.pth`). Flag on the loader signature — `*-setup.pth` naming or payload-loader markers
  (`_index.js`, `.bun_ran`, `oven-sh/bun`, `sys.path` search) — **never on existence**. A non-allowlisted
  *executable* `.pth` with no marker is REVIEW (worth an eyeball), not HIT.
- **B. `.abi3.so` is a normal compiled extension** (numpy, cryptography, pydantic-core ship dozens).
  Flag only the known malicious filenames (`PYPI_KNOWN_SO`: `ensmallen_haswell.abi3.so`,
  `ensmallen_core2.abi3.so`) as HIT, or an `.abi3.so` co-located with an `_index.js` as REVIEW. Never
  flag a bare `.so`.
- **C. The bioinformatics names are REAL packages** (`embiggen`, `ensmallen`, `gpsea`,
  `phenopacket-store-toolkit`, `ppkt2synergy`, `pyphetools`) — only specific versions were poisoned.
  Name-only = REVIEW, exact bad version = HIT (`PYPI_WATCH_NAMES` + `PYPI_KNOWN_BAD`). The @tanstack
  watchlist lesson, PyPI edition. The typosquats (`rsquests`/`tlask`/`rlask`) and MCP lookalikes
  (`langchain-core-mcp`, `openai-mcp`, `tiktoken-mcp`, …) are attacker-specific → `PYPI_HIT_NAMES`
  (name match = HIT). Keep the `-mcp`/typo suffixes in the boundary regexes so the REAL `langchain-core`,
  `openai`, `tiktoken`, `requests`, `flask` never match.
- **D. Normalize names per PEP 503 before comparing** (`normalize_pypi_name`: lowercase, collapse runs
  of `-_.` to a single `-`). `langchain_core_mcp` ≡ `langchain-core-mcp`; skip this and installed-dist
  matches silently miss.
- **E. LLM anti-analysis.** The malicious `_index.js` opens with a non-executing comment header
  engineered to trigger AI-safety refusals / prompt injection in LLM-first triage. The scanner greps
  **byte markers only**, prints just the matched lines (never the file body), and emits a warning not
  to paste a flagged `_index.js` into an AI assistant. Do not add any step that feeds `_index.js`
  contents to a model.
- **F. StepSecurity strings are legit defensive tooling the malware targets** (`harden-runner`,
  `agent/api/app.stepsecurity.io`). Presence of the string ≠ compromise — only a **hosts-file
  redirection** of those domains is a (REVIEW) tamper signal, handled in `run_common_checks`.

### PyPI false-negative / evasion rules

- **G. Parse the resolved version from lock blocks**, not just the requirement range. `scan_pyreq_pairs`
  reads `name`/`version` out of `[[package]]` TOML blocks (poetry/pdm/uv) and `"version": "==x"` JSON
  (Pipfile.lock), in addition to `name==version` pins (requirements/pyproject). Installed dists are
  read from `*.dist-info/METADATA` + `*.egg-info/PKG-INFO` (`Name:`/`Version:`).
- **H. Handle the split loader.** A `*-setup.pth` may reference an `_index.js` that is not in its own
  wheel (the `langchain-core-mcp` variant searches `sys.path`), so the `.pth` is flagged on its loader
  markers/naming independently of whether a local `_index.js` exists, and stray `_index.js` files in a
  Python env are flagged separately.

## Verification

After any change, run the smoke tests — they exit non-zero on any failure, so they double as a CI
gate:

```sh
./tests/smoke.sh                   # 0 = all passed, 1 = a failure
```

`tests/smoke.sh` codifies what used to be done by hand:

- **Static check (shellcheck) — expected but optional.** The harness runs `shellcheck -x scan.sh`
  automatically *when shellcheck is installed* (the `-x` makes it follow the sourced `lib/*.sh`) and
  fails the run if it reports anything. When shellcheck is absent it prints a `WARN` and skips (so the
  suite still runs on a bare box), but shellcheck is expected in CI/dev — install it for full
  coverage. It must stay clean.
- **Regression check** — greps `scan.sh` *and* `lib/*.sh` for the fabricated indicators (see list
  above) and fails if any reappear.
- **Router dispatch** — asserts `--ecosystem npm` emits npm sections and no `pypi:` sections (and the
  converse), so the dispatcher cannot silently run the wrong leg.
- **PyPI positive fixture** — a fake site-packages with an installed `langchain-core-mcp@1.4.2`
  (normalized from the underscore dist-info name), an installed bioinformatics exact-bad
  `ensmallen@0.8.101` (HIT) and a benign `ensmallen@0.8.100` in requirements (REVIEW), a
  `langchain_core-setup.pth` split-loader, an `_index.js` with `getBunPath`, a known
  `ensmallen_haswell.abi3.so` beside it, a pinned typosquat `rsquests==2.34.3`, and temp `.bun_ran` /
  `.sshu-setup.js`. Asserts each fires and exit is `2`.
- **PyPI negative fixture** — a clean env: `numpy` dist-info + a bare `_core.abi3.so` (no `_index.js`),
  legit executable `.pth` (`_virtualenv.pth`, `distutils-precedence.pth`, `__editable__.foo.pth`), and
  benign deps including the REAL `langchain-core`/`openai`/`requests` and a non-poisoned `ensmallen`.
  Asserts `CLEAN`, exit `0`, zero `HIT:` lines, and that the bare `.abi3.so` / legit `.pth` do not fire.
- **Positive fixture** — a throwaway tree with a weaponized `binding.gyp` (`<!(node index.js …)`)
  beside an `index.js` containing `globalThis.getBunPath`, a lockfile referencing
  `@vapi-ai/server-sdk` (HIT), `@tanstack/react-router` exact bad version (HIT), and
  `@tanstack/react-query` benign version (REVIEW), a `.claude/setup.mjs`, malicious
  `.claude/settings.json`, temp Bun/payload artifacts, and a `.vscode/tasks.json` with `runOn:
  folderOpen`. Asserts each fires, exit code is `2`, that a fake `npm` on `PATH` is not invoked, and
  that the co-located legit `node-addon-api` `binding.gyp` and plain `.gemini/settings.json` do
  **not** fire.
- **Negative fixture** — a clean tree (legit `node-addon-api` `binding.gyp`, plain
  `.gemini/settings.json`, a benign `@redhat-cloud-services` version, and a `@tanstack` dep). Asserts
  verdict `CLEAN`, exit `0`, and zero `HIT:` lines.

The harness redirects `HOME`, `/tmp` checks, and `/etc/hosts` checks to temp fixtures so the host's
real `~/.claude` etc. cannot skew results; the system-global sections (systemd, `/etc/sudoers.d`)
assume a clean host and only emit REVIEW/info there on a normal machine. `bash -n scan.sh` (syntax)
is implied by both shellcheck and actually invoking the script in the fixtures.

When adding a new detection, add a matching positive assertion (and, if it touches a file type that
legitimately exists, a negative assertion proving it doesn't false-positive) to `tests/smoke.sh`.
