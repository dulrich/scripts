# AGENTS.md — npm-ioc

Guidance for any AI agent (or human) modifying `scan.sh`. This file is the design contract; read it
before changing detection logic. See [`README.md`](./README.md) for user-facing docs.

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
   `keytar`, `@parcel/watcher`, …). Presence is not a finding. The legitimate idiom is
   `<!(node -p "require('node-addon-api').include_dir")` — running `node -p` on an *expression*. The
   malicious form runs a *script file*: `<!(node index.js > /dev/null 2>&1 && echo stub.c)`.
   Discriminate on a `.js` being executed via command substitution, and treat the obfuscated payload
   markers in the sibling root `index.js` (`getBunPath`, `aes-128-gcm` decipher, `oven-sh/bun`
   download) as the definitive signal.
2. **Broad legit scopes are a watchlist, not a HIT.** `@tanstack`, `@uipath`, `@mistralai`, `@antv`,
   `@squawk`, `@opensearch-project` are widely-used libraries where only *specific versions* were
   compromised (CVE-2026-45321 for `@tanstack`). Matching the scope alone (`@tanstack/react-query` is
   everywhere) is a false-positive cannon — report these as REVIEW with a "verify versions" note.
   Only obscure/typosquat names (`autotel`, `awaitly`, `@vapi-ai`, `ai-sdk-ollama`, `chalk-tempalte`,
   …) are safe to prefix-match as HITs.
3. **Legit config files are content-checked, not existence-checked.** `.gemini/settings.json` and
   `.claude/settings.json` are normal config files the worm *injects into* — flag only on malicious
   content (`bun run`, `setup.mjs`, IOC strings). Only attacker-*invented* names (`setup.mjs`,
   `setup.mdc`, `.github/setup.js`) are flagged on existence.
4. **`if perl -ne '…'` is always true.** `perl -ne` exits `0` whether or not the pattern matched, so
   keying a finding off its exit status flags every file scanned. Capture and test the OUTPUT string
   instead. (This bug, inherited from the draft, made any machine with a `CLAUDE.md` report
   COMPROMISED.) The same "test output, not exit status" caution applies to any added `grep -q`/perl
   probes.

## Verification

After any change, run the smoke tests — they exit non-zero on any failure, so they double as a CI
gate:

```sh
./tests/smoke.sh                   # 0 = all passed, 1 = a failure
```

`tests/smoke.sh` codifies what used to be done by hand:

- **Static check (shellcheck) — expected but optional.** The harness runs `shellcheck scan.sh`
  automatically *when shellcheck is installed* and fails the run if it reports anything. When
  shellcheck is absent it prints a `WARN` and skips (so the suite still runs on a bare box), but
  shellcheck is expected in CI/dev — install it for full coverage. It must stay clean.
- **Regression check** — greps `scan.sh` for the fabricated indicators (see list above) and fails if
  any reappear.
- **Positive fixture** — a throwaway tree with a weaponized `binding.gyp` (`<!(node index.js …)`)
  beside an `index.js` containing `globalThis.getBunPath`, a lockfile referencing
  `@vapi-ai/server-sdk` (HIT) and `@tanstack/react-query` (REVIEW), a `.claude/setup.mjs`, and a
  `.vscode/tasks.json` with `runOn: folderOpen`. Asserts each fires, exit code is `2`, and that the
  co-located legit `node-addon-api` `binding.gyp` and plain `.gemini/settings.json` do **not** fire.
- **Negative fixture** — a clean tree (legit `node-addon-api` `binding.gyp`, plain
  `.gemini/settings.json`, a `@tanstack` dep). Asserts verdict `CLEAN`, exit `0`, and zero `HIT:`
  lines.

The harness redirects `HOME` to an empty temp dir so the host's real `~/.claude` etc. cannot skew
results; the system-global sections (systemd, `/etc/sudoers.d`, `/tmp` bun staging) assume a clean
host and only emit REVIEW/info there on a normal machine. `bash -n scan.sh` (syntax) is implied by
both shellcheck and actually invoking the script in the fixtures.

When adding a new detection, add a matching positive assertion (and, if it touches a file type that
legitimately exists, a negative assertion proving it doesn't false-positive) to `tests/smoke.sh`.
