# npm-ioc

A local indicator-of-compromise scanner for the June 2026 **TeamPCP** npm supply-chain campaign —
known across advisories as **"Miasma"**, **"Phantom Gyp"**, and **"mini-Shai-Hulud"**. The campaign
is a self-propagating worm that steals every reachable credential (npm, GitHub, AWS/GCP/Azure,
Kubernetes, Vault, SSH) and installs persistence in developer tooling — Claude Code, Cursor, Gemini,
and VS Code config — so it survives removal of the original npm package. It also ships a dead-man's
switch (a `gh-token-monitor` daemon) that recursively deletes files if it detects its stolen token
was revoked.

`scan.sh` is **detection-only and read-only**. It never touches credentials or kills processes.

## Usage

```sh
./scan.sh [scan-root]      # default scan-root: $HOME
```

Exit codes:

- `0` — CLEAN: no definitive local indicators found
- `2` — HIT: one or more indicators found

`REVIEW` lines are informational (things that are usually benign but worth a human glance — e.g. a
legitimate `@tanstack` dependency, or a `SessionStart` hook you may have added yourself); they do
**not** change the exit code.

### If something fires — order matters

The malware wipes `$HOME` if it sees its access cut, so follow this order:

1. **CHECK** (this script) — do not panic-revoke.
2. **ISOLATE** — disconnect the machine from the network.
3. **CLEAN** — screenshot the evidence, then remove the injected files / daemon.
4. **ROTATE** — only now, and only from a *different, trusted* machine: npm → GitHub → SSH → cloud.

## What it checks

1. Affected package families in installed trees (`npm ls`)
2. Weaponized `binding.gyp` in `node_modules` (the Phantom Gyp `node-gyp` execution trick)
3. Affected-package references in lockfiles (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, …)
4. Injected AI-assistant / editor backdoor files (`.claude/setup.mjs`, `.cursor/rules/setup.mdc`,
   `.github/setup.js`, …) and malicious content in legit config files
5. Claude Code / OpenCode `SessionStart` hook persistence
6. VS Code `tasks.json` `folderOpen` auto-run persistence
7. `gh-token-monitor` dead-man's-switch daemon (systemd / launchctl)
8. Bun runtime artifacts staged in `/tmp/b-*` (the off-Node evasion runtime)
9. Passwordless-sudo persistence (`/etc/sudoers.d`)
10. Obfuscated-payload code markers in source trees
11. Zero-width-character injection in agent context files (`CLAUDE.md`, `AGENTS.md`, …)
12. Shell profile (`.bashrc`/`.zshrc`/…) modifications that download Bun

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

**Wave 1 — Miasma, `@redhat-cloud-services` (June 1, 2026).** Specific versions were compromised
inside a legitimate scope. `scan.sh` embeds the Microsoft/Snyk exact-version snapshot as `HIT`
signals and reports other `@redhat-cloud-services/*` sightings as `REVIEW`. Examples include
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
- **CVE-2026-45321.** The only CVE assigned to the campaign — a chained exploitation of three
  weaknesses in TanStack's GitHub Actions CI/CD that poisoned 42 `@tanstack` packages (CVSSv3 9.6).
  <https://www.tenable.com/cve/CVE-2026-45321>

### Origin

This tool began life as a community checklist shared in an r/ClaudeAI PSA, first drafted into a
script by a web LLM. That draft contained several **fabricated** indicators that appear in no
advisory; it was then rewritten against the sources above, with every indicator verified or removed.
See [`AGENTS.md`](./AGENTS.md) for the list of fabricated indicators that must not be reintroduced.
