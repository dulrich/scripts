# pkg-ioc

A local indicator-of-compromise scanner for the June 2026 **TeamPCP** software supply-chain campaign
family — known across advisories as **"Miasma"**, **"Phantom Gyp"**, **"Shai-Hulud"**, and the PyPI
**"Hades"** branch. It is one self-propagating worm that keeps changing shape across package
ecosystems: it steals every reachable credential (npm, PyPI, GitHub, RubyGems, JFrog, AWS/GCP/Azure,
Kubernetes, Vault, SSH, Docker, shell histories, `.env`, AI dev-tool config) and installs persistence
so it survives removal of the original package. It also ships a dead-man's switch (a
`gh-token-monitor` daemon) that recursively deletes files if it detects its stolen token was revoked.

`scan.sh` is a **router**: it dispatches to per-ecosystem sub-scanners (`lib/npm.sh`, `lib/pypi.sh`)
and shared host-level checks (`lib/common.sh`). It is **detection-only and read-only** — it never
touches credentials or kills processes.

## Usage

```sh
./scan.sh [--ecosystem npm|pypi|all] [scan-root]   # defaults: --ecosystem all, scan-root $HOME
./scan.sh ~/code                                   # scan a specific tree, both ecosystems
./scan.sh --ecosystem pypi ~/venvs                 # PyPI leg only
```

Exit codes:

- `0` — CLEAN: no definitive local indicators found
- `2` — HIT: one or more indicators found

`REVIEW` lines are informational (things that are usually benign but worth a human glance — e.g. a
legitimate `@tanstack` dependency, a non-poisoned version of a real bioinformatics package, or an
editable-install `.pth` you may have created); they do **not** change the exit code.

### If something fires — order matters

The malware wipes `$HOME` if it sees its access cut, so follow this order:

1. **CHECK** (this script) — do not panic-revoke.
2. **ISOLATE** — disconnect the machine from the network.
3. **CLEAN** — screenshot the evidence, then remove the injected files / daemon.
4. **ROTATE** — only now, and only from a *different, trusted* machine: npm/PyPI → GitHub → SSH → cloud.

## What it checks

**npm leg** (`lib/npm.sh`):

1. Affected package families in installed `node_modules` trees
2. Weaponized `binding.gyp` in `node_modules` (the Phantom Gyp `node-gyp` execution trick)
3. Affected-package references in lockfiles (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, …)
4. Injected AI-assistant / editor backdoor files (`.claude/setup.mjs`, `.cursor/rules/setup.mdc`,
   `.github/setup.js`, …) and malicious content in legit config files
5. Claude Code / OpenCode `SessionStart` hook persistence
6. VS Code `tasks.json` `folderOpen` auto-run persistence
7. Obfuscated-payload code markers in JS source trees

**PyPI / Hades leg** (`lib/pypi.sh`):

1. Affected packages in installed distributions (`*.dist-info/METADATA`, `*.egg-info/PKG-INFO`) —
   typosquats / MCP lookalikes as HIT, real bioinformatics packages version-checked (HIT on the exact
   poisoned version, REVIEW on name)
2. Affected packages in dependency manifests (`requirements*.txt`, `pyproject.toml`, `poetry.lock`,
   `Pipfile.lock`, `pdm.lock`, `uv.lock`, `environment.yml`)
3. Executable `*-setup.pth` startup hooks and `.pth` payload-loader markers (incl. the
   `langchain-core-mcp` split loader that searches `sys.path` for its payload)
4. Staged `_index.js` JavaScript stealer payloads (byte-marker grep only — see the LLM anti-analysis
   note below)
5. Trojanized native `.abi3.so` extensions (known filenames, or co-located with `_index.js`)
6. Known malicious artifact SHA-256 hashes (`*.whl`, `*-setup.pth`)
7. Hades temp artifacts (`.bun_ran` run-once marker, `.sshu-setup.js` SSH propagation file)

**Shared host-level** (`lib/common.sh`, run once regardless of ecosystem):

1. `gh-token-monitor` dead-man's-switch daemon (systemd / launchctl)
2. Bun runtime artifacts staged in `/tmp/b-*` (the off-Node evasion runtime)
3. Passwordless-sudo persistence (`/etc/sudoers.d`)
4. Hosts-file DNS redirection of developer / registry / StepSecurity-telemetry domains
5. Zero-width-character injection in agent context files (`CLAUDE.md`, `AGENTS.md`, …)
6. Shell profile (`.bashrc`/`.zshrc`/…) modifications that download Bun

> **LLM anti-analysis.** The malicious PyPI `_index.js` opens with a fake prompt-injection comment
> header designed to derail AI-assisted triage. This scanner only greps byte markers and prints
> matched lines — **do not paste a flagged `_index.js` into an AI assistant.**

## Limitations

This scanner only sees the local filesystem. Several indicators can only be confirmed on GitHub and
must be checked by hand (the script prints reminders): your account security log, attacker-created
exfil repos (named like `adjective-creature-<0-99999>`, or with the description
`Miasma: The Spreading Blight`), and your npm publish / GitHub audit history for activity you did not
perform.

## Affected versions (quick reference)

A non-exhaustive snapshot for fast triage. This is a self-propagating worm that republishes new
poisoned versions using stolen maintainer tokens, so treat any static list (including this one) as
stale — **cross-check the live lists below** before trusting it. `scan.sh` parses `node_modules`
and lockfiles directly instead of trusting `npm ls`; it flags advisory-backed exact versions as
`HIT` and broad legitimate scopes as `REVIEW`.

**Wave 1 — Miasma, `@redhat-cloud-services` (June 1, 2026).** Microsoft's IOC table states *every*
package on the `@redhat-cloud-service` account was compromised, and the worm republishes new poisoned
versions, so `scan.sh` treats **any `@redhat-cloud-services/*` sighting as a `HIT`** (family match) —
not REVIEW — with the Microsoft/Snyk exact-version snapshot supplying the precise version label.
Unlike `@tanstack` (a ubiquitous dependency on the REVIEW watchlist), this scope is rarely a clean
transitive dep, so the family HIT is low-FP. Examples include
`frontend-components` (7.7.2, 7.7.3, 7.7.5), `frontend-components-utilities`,
`frontend-components-notifications`, `frontend-components-advisor-components`,
`frontend-components-testing`, `chrome`, `types`, `rbac-client`, `host-inventory-client`,
`compliance-client`, `remediations-client`, `hcc-kessel-mcp`, and ~two dozen more.

**Wave 2 — Phantom Gyp (June 3–4, 2026).** 57 packages / 286+ malicious versions in under two hours:

| Package / family | Affected versions |
|---|---|
| `@vapi-ai/server-sdk` | 0.11.1, 0.11.2, 1.2.1, 1.2.2 |
| `ai-sdk-ollama` | 0.13.1, 1.1.1, 2.2.1, 3.8.5 |
| `autotel` (+ ~40 `autotel-*` family pkgs) | 2.26.4, 3.4.3 (family spans many versions) |
| `awaitly`, `executable-stories*`, `node-env-resolver`, `wrangler-deploy` | multiple (maintainer `jagreehal`) |
| `mountly`, `effect-analyzer`, `http-uploader-dev` | multiple |
| `@evolvconsulting/evolv-coder-lite` | 1.2.0 |
| `@jagreehal/workflow` | 1.16.1 |

**mini-Shai-Hulud / CVE-2026-45321 — TanStack & friends (weeks earlier).** **Specific versions only**
inside otherwise-legitimate scopes — verify exact versions, do **not** assume the whole scope is bad:
`@tanstack` (42 packages), `@uipath`, `@mistralai`, `@opensearch-project`, `@antv`, `@squawk`. These
are on `scan.sh`'s REVIEW watchlist rather than auto-flagged for this reason.

**Copycats (open-sourced worm, May 2026).** `chalk-tempalte` (typosquat of `chalk`),
`@deadcode09284814/axios-util`, `axois-utils`, `color-style-utils`.

**PyPI / Hades wave (June 8, 2026).** 23 newer artifacts on top of the weekend wave's 37 wheels.
`scan.sh` treats the typosquats and MCP lookalikes as name-match **HITs**, and the real
bioinformatics packages as a version-checked **REVIEW** watchlist (HIT only on the exact poisoned
version):

| Class | Packages (exact poisoned versions) |
|---|---|
| Typosquats → HIT | `rsquests` 2.34.3 (requests), `tlask` 3.1.4 / `rlask` 3.1.7 (flask) |
| MCP / AI lookalikes → HIT | `langchain-core-mcp` 1.4.2/1.4.3, `instructor-mcp` 1.15.2/1.15.3, `openai-mcp` 2.41.1/2.41.2, `tiktoken-mcp` 0.13.1/0.13.2, `ray-mcp-server` 0.2.1, `mem8` 6.0.1, `mflux-streamlit` 0.0.3/0.0.4, `orchestr8-platform` 3.3.2, `dreamgen` 1.8.1 |
| Real bioinformatics → REVIEW (HIT on exact ver) | `embiggen` 0.11.97, `ensmallen` 0.8.101, `gpsea` 0.9.14, `phenopacket-store-toolkit` 0.1.7, `ppkt2synergy` 0.1.1, `pyphetools` 0.9.120 |

Delivery is via three branches: a `*-setup.pth` executable startup hook + bundled `_index.js`; a
trojanized native `.abi3.so` (`ensmallen_haswell.abi3.so`, `ensmallen_core2.abi3.so`) that runs the
payload at import time; and the `langchain-core-mcp` split loader whose `.pth` searches `sys.path` for
an `_index.js` it does not ship. Notable hashes: `langchain_core_mcp-1.4.2-py3-none-any.whl`
(`6d332f81…ff7d9`), `langchain_core-setup.pth` (`6506d317…d01b2`).

### Live / updated lists

- **StepSecurity — affected-packages table** (maintained as new packages are identified; the most
  complete wave-2 list): <https://www.stepsecurity.io/blog/binding-gyp-npm-supply-chain-attack-spreads-like-worm>
- **Snyk — `@redhat-cloud-services` lead advisory** (per-package version cutoffs, live status):
  <https://security.snyk.io/vuln/SNYK-JS-REDHATCLOUDSERVICESFRONTENDCOMPONENTS-17117384>
- **Tenable — CVE-2026-45321** (the `@tanstack` leg): <https://www.tenable.com/cve/CVE-2026-45321>

## Sources

High-value advisories this scanner's indicators are derived from. Every IOC in `scan.sh` traces back
to one of these — see [`AGENTS.md`](./AGENTS.md) for the provenance contract.

- **Microsoft Threat Intelligence — "Preinstall to persistence: Inside the Red Hat npm Miasma
  credential-stealing campaign" (2026-06-02).** The primary technical teardown of the full attack
  chain; source of the SHA-256 file hashes, Microsoft Defender detection names, and KQL hunting
  queries (e.g. payload writes to `/tmp/p*.js`, the `node → sh → bun` process lineage).
  <https://www.microsoft.com/en-us/security/blog/2026/06/02/preinstall-persistence-inside-red-hat-npm-miasma-credential-stealing-campaign/>
- **StepSecurity — "Miasma npm Supply Chain Attack: Self-Spreading Worm via Phantom Gyp" (wave 2,
  2026-06-03).** Documents the `binding.gyp` `node-gyp rebuild` execution trick (no declared install
  script), the affected-package/version table, the Bun-runtime download for off-Node evasion, and
  the AI-assistant config poisoning vector (`.claude/setup.mjs`, `.cursor/rules/setup.mdc`, etc.).
  <https://www.stepsecurity.io/blog/binding-gyp-npm-supply-chain-attack-spreads-like-worm>
- **Snyk — "Miasma Attack Hits Red Hat npm Packages."** Advisory for the `@redhat-cloud-services`
  scope (rated CVSS v4.0 9.3, Critical, exploit maturity "Attacked"), with concise detection and
  remediation steps and lockfile-grep guidance.
  <https://snyk.io/blog/miasma-supply-chain-attack-malicious-code-redhat-cloud-services-npm-packages/>
- **Tenable — "Mini Shai-Hulud FAQ" (TeamPCP campaign).** Campaign lineage and scope across the
  TeamPCP waves; source of the `gh-token-monitor` dead-man's-switch detail and the active copycats,
  and the home of the campaign's lone CVE.
  <https://www.tenable.com/blog/mini-shai-hulud-frequently-asked-questions>
- **Socket.dev — "Mini Shai-Hulud, Miasma, and Hades Worms Target Bioinformatics and MCP Developers
  via Malicious PyPI Wheels" (2026-06-08).** The PyPI leg: the three delivery branches (`.pth`
  startup hooks, trojanized `.abi3.so` native extensions, the `langchain-core-mcp` split loader), the
  23-artifact IOC list and notable hashes, the `_index.js` LLM anti-analysis header, and the
  StepSecurity-targeting host indicators. Source for every indicator in `lib/pypi.sh`.
  <https://socket.dev/blog/mini-shai-hulud-miasma-and-hades-worms-target-bioinformatics-and-mcp-developers-via-malicious>
- **Socket.dev — "Shai-Hulud Descends to Hades: Miasma Worm Campaign Spreads with New PyPI Wave."**
  The weekend PyPI wave (37 wheels): the original `*-setup.pth` + `_index.js` pattern and the shared
  Hades stealer payload markers.
  <https://socket.dev/blog/shai-hulud-descends-to-hades-miasma-pypi-wave>
- **CVE-2026-45321.** The only CVE assigned to the campaign — a chained exploitation of three
  weaknesses in TanStack's GitHub Actions CI/CD that poisoned 42 `@tanstack` packages (CVSSv3 9.6).
  <https://www.tenable.com/cve/CVE-2026-45321>

### Origin

This tool began life as a community checklist shared in an r/ClaudeAI PSA, first drafted into a
script by a web LLM. That draft contained several **fabricated** indicators that appear in no
advisory; it was then rewritten against the sources above, with every indicator verified or removed.
See [`AGENTS.md`](./AGENTS.md) for the list of fabricated indicators that must not be reintroduced.
