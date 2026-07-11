# AGENTS.md

Guidance for automated agents working in this repo. See `CLAUDE.md` for the
full architecture (alias chain, the `util` router, config pattern).

## License

This repository is **CC0 1.0** (public domain) — see `LICENSE`. Anything added
here must be CC0 / public-domain compatible. Do not introduce copyleft
(e.g. GPL) or otherwise restrictively-licensed code into the tracked tree.
Vendored subdirectories keep their own compatible licenses (`build_system/`
public domain, `pkg-ioc/` CC0).

## Public repo — keep private detail out

This is the public repo. Private and machine-specific content (`work-aliases.sh`,
private `util/*` scripts, secrets, host-specific configs) belongs in the
separate private overlay repo and is gitignored here. Do not commit hostnames,
credentials, tokens, or personal paths.
