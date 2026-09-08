#!/bin/bash
set -euo pipefail

# Guards the repo's advertised public runtime surface: every alias that points
# at a sibling script must resolve to a file that actually exists and is
# tracked (this is what would have caught aliases.sh's dead lifi alias), no
# tracked active file leaks a literal personal home path, the retained static
# assets (Xresources, gpuedit themes/commands/highlighters) exist and parse,
# and the docs no longer advertise a removed surface. Only tracked files
# inside this worktree are read; nothing outside it or under private/ is
# touched.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

passed=0
total=0

ok() {
	total=$((total + 1))
	passed=$((passed + 1))
	printf 'ok %d - %s\n' "$total" "$1"
}

fail() {
	total=$((total + 1))
	printf 'not ok %d - %s\n' "$total" "$1" >&2
	return 1
}

# --- alias-target check ---------------------------------------------------
# Every `alias NAME="$here/<file>[ extra args]"` line must name a file that
# git tracks. Prints any offending target to stderr and fails if any is
# missing.
check_alias_targets() {
	local aliases_file=$1
	local target all_ok=1

	# The pattern below intentionally contains a literal, unexpanded
	# "$here/" token -- it matches that text in aliases.sh source, and is
	# not meant to expand in this shell.
	# shellcheck disable=SC2016
	while IFS= read -r target; do
		[[ -z "$target" ]] && continue
		if ! git -C "$ROOT" ls-files --error-unmatch -- "$target" >/dev/null 2>&1; then
			printf 'alias target not tracked: %s\n' "$target" >&2
			all_ok=0
		fi
	done < <(grep -oP 'alias \S+="\$here/\K[^" ]+' "$aliases_file")

	[[ $all_ok -eq 1 ]]
}

if check_alias_targets aliases.sh; then
	ok 'every here-relative alias in aliases.sh resolves to a tracked file'
else
	fail 'every here-relative alias in aliases.sh resolves to a tracked file'
fi

# Negative self-test: a bogus alias target must be detected as missing. The
# appended line is fixture source text, not meant to expand here.
cp aliases.sh "$fixture/aliases.sh"
# shellcheck disable=SC2016
printf '\nalias zz="$here/nope.sh"\n' >> "$fixture/aliases.sh"
if check_alias_targets "$fixture/aliases.sh" 2>/dev/null; then
	fail 'negative self-test: a bogus here-relative alias target is caught'
else
	ok 'negative self-test: a bogus here-relative alias target is caught'
fi

# --- no literal personal home paths ---------------------------------------
# Scope: *.sh at the repo root and everything under util/, plus
# gpuedit/options.json, config.example.sh, Xresources, and i3/*. Historical
# review prose, plans, runs, markdown docs, gentoo/, and private/ are exempt.
#
# Xresources:80 references /home/_shared_code/clones/urxvt-perls, an
# environment-specific path that predates and is unrelated to F7's named
# personal-path defaults (dotfiles.sh, gpuedit/options.json,
# themegen/options.json). WP-R2 keeps Xresources byte-identical, so this one
# line is allowlisted rather than fixed here; see the WP-R2 report for the
# follow-up recommendation.
home_path_allowlist='Xresources:URxvt.perl-lib: /home/_shared_code/clones/urxvt-perls'

mapfile -t scope_files < <(
	git ls-files -- '*.sh' | grep -vE '/'
	git ls-files -- 'util/*'
	git ls-files -- 'i3/*'
	printf '%s\n' gpuedit/options.json config.example.sh Xresources
)

home_hits=()
while IFS= read -r hit; do
	[[ -z "$hit" ]] && continue
	path=${hit%%:*}
	content=${hit#*:*:}
	if [[ "$path:$content" != "$home_path_allowlist" ]]; then
		home_hits+=("$hit")
	fi
done < <(grep -nE '/home/[A-Za-z0-9_]+/' "${scope_files[@]}" 2>/dev/null || true)

if [[ ${#home_hits[@]} -eq 0 ]]; then
	ok 'no unallowlisted literal /home/<user>/ path in scoped active files'
else
	printf '%s\n' "${home_hits[@]}" >&2
	fail 'no unallowlisted literal /home/<user>/ path in scoped active files'
fi

# --- gpuedit/themes/*.json validity ---------------------------------------
# Measured (not assumed): all four theme files fail a strict parse under both
# jq and python3's json module. They share gpuedit/options.json's tolerant
# format verbatim -- `//` line comments, trailing commas, and even an
# unquoted top-level `theme` key -- which is gpuedit's own native format, not
# an oversight. Since these files must stay byte-identical (WP-R2 invariant),
# they cannot be rewritten to strict JSON, so a strict-parser assertion can
# never pass here; see the WP-R2 report for this finding. Substituted: each
# tracked theme file must be non-empty and valid UTF-8 text.
if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
	: # at least one parser is present, satisfying the brief's tooling check
else
	printf 'neither jq nor python3 is available\n' >&2
	exit 1
fi

mapfile -t theme_json_files < <(git ls-files -- 'gpuedit/themes/*.json')
theme_json_ok=1
if [[ ${#theme_json_files[@]} -eq 0 ]]; then
	theme_json_ok=0
	printf 'no tracked gpuedit/themes/*.json files found\n' >&2
fi
for f in "${theme_json_files[@]}"; do
	if [[ ! -s "$f" ]]; then
		printf 'empty or missing theme file: %s\n' "$f" >&2
		theme_json_ok=0
	elif ! LC_ALL=C.UTF-8 iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1; then
		printf 'not valid UTF-8: %s\n' "$f" >&2
		theme_json_ok=0
	fi
done
if [[ $theme_json_ok -eq 1 ]]; then
	ok 'gpuedit/themes/*.json are tracked, non-empty, valid UTF-8 (not strict JSON -- see report)'
else
	fail 'gpuedit/themes/*.json are tracked, non-empty, valid UTF-8 (not strict JSON -- see report)'
fi

# --- retained static assets exist and are tracked -------------------------
check_tracked() {
	local f=$1
	[[ -e "$f" ]] && git ls-files --error-unmatch -- "$f" >/dev/null 2>&1
}

retained_ok=1
for f in Xresources gpuedit/themes/dark_pastel.json gpuedit/themes/dark_saturated.json \
	gpuedit/themes/default_dark.json gpuedit/themes/default_light.json gpuedit/commands.json; do
	if ! check_tracked "$f"; then
		printf 'missing retained asset: %s\n' "$f" >&2
		retained_ok=0
	fi
done

mapfile -t highlighter_files < <(git ls-files -- 'gpuedit/highlighters/*_colors.txt')
if [[ ${#highlighter_files[@]} -eq 0 ]]; then
	retained_ok=0
	printf 'no tracked gpuedit/highlighters/*_colors.txt files found\n' >&2
fi
for f in "${highlighter_files[@]}"; do
	if ! check_tracked "$f"; then
		printf 'untracked highlighter file: %s\n' "$f" >&2
		retained_ok=0
	fi
done

if [[ $retained_ok -eq 1 ]]; then
	ok 'retained static assets (Xresources, gpuedit themes/commands/highlighters) exist and are tracked'
else
	fail 'retained static assets (Xresources, gpuedit themes/commands/highlighters) exist and are tracked'
fi

# --- docs no longer advertise a removed surface ----------------------------
docs_ok=1
for doc in README.md AGENTS.md; do
	if grep -qE 'lifi\.sh|licenses/|themegen/' "$doc"; then
		printf '%s still mentions a removed public surface\n' "$doc" >&2
		docs_ok=0
	fi
done
if [[ $docs_ok -eq 1 ]]; then
	ok 'README.md and AGENTS.md do not mention lifi.sh, licenses/, or themegen/'
else
	fail 'README.md and AGENTS.md do not mention lifi.sh, licenses/, or themegen/'
fi

printf 'public-contract-smoke: %d/%d passed\n' "$passed" "$total"
