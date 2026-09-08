# shellcheck shell=bash
# ============================================================================
# pkg-ioc :: lib/inventory.sh
#
# ONE bounded walk per distinct traversal POLICY, shared by every check that has
# that policy (AGENTS.md documents the classes). Sourced by scan.sh after
# common.sh and before the ecosystem modules; defines data and functions only.
#
#   P1  INVENTORY_ROOT    -- $ROOT, pruning */node_modules and */.git.
#   P2  INVENTORY_MODULES -- $ROOT *inside* node_modules, deliberately unpruned;
#                            it targets exactly what P1 prunes, so never merge.
#   P3  (elsewhere)       -- the agent-config dirs, unit dirs, temp roots and the
#                            _index.js sibling probe keep their own find calls.
#
# Reach is preserved PER CONSUMER: each walk prints the UNION of its consumers'
# name/path predicates and every consumer re-applies its own through
# inventory_select, so no check sees a file it did not see before. `-type f` is
# deliberately NOT on the shared walk -- some call sites have no type test, where
# a SYMLINK named package.json is listed and read through -- so select's "file"
# mode reproduces find's -type f only for the sites that had it.
#
# Adding a check: filter an existing inventory (extending the union below when it
# needs a new name) or justify a new bounded walk. Never add a `find "$ROOT"`.
# Bash 3.2 compatible (macOS system bash): no mapfile, no namerefs.
# ============================================================================

INVENTORY_ROOT=(); INVENTORY_MODULES=()

# P1 union: every -name/-path predicate its consumers use, so each can re-filter
# this one walk (the consumers are in npm.sh, pypi.sh and common.sh).
inventory_build_root() {
  INVENTORY_ROOT=(); local p
  while IFS= read -r -d '' p; do INVENTORY_ROOT+=("$p"); done < <(find "$1" \
    \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    \( -name 'package.json' -o -name 'package-lock.json' -o -name 'npm-shrinkwrap.json' \
      -o -name 'yarn.lock' -o -name 'pnpm-lock.yaml' -o -name 'binding.gyp' \
      -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name 'setup.mdc' \
      -o -name 'settings.json' -o -name 'settings.local.json' -o -name 'tasks.json' \
      -o -name 'CLAUDE.md' -o -name 'AGENTS.md' -o -name '.cursorrules' \
      -o -name 'METADATA' -o -name 'PKG-INFO' -o -name '*.pth' -o -name '*.abi3.so' \
      -o -name 'requirements*.txt' -o -name 'pyproject.toml' -o -name 'poetry.lock' \
      -o -name 'Pipfile' -o -name 'Pipfile.lock' -o -name 'pdm.lock' -o -name 'uv.lock' \
      -o -name 'environment.yml' -o -name 'environment.yaml' -o -name 'langchain_core_mcp-*.whl' \) \
    -print0 2>/dev/null)
}

# P2: the node_modules interior P1 prunes -- installed package.json + binding.gyp.
inventory_build_modules() {
  INVENTORY_MODULES=(); local p
  while IFS= read -r -d '' p; do INVENTORY_MODULES+=("$p"); done < <(find "$1" \
    \( -path '*/node_modules/*/package.json' -o -path '*/node_modules/*/binding.gyp' \) \
    -print0 2>/dev/null)
}

inventory_root() { [ ${#INVENTORY_ROOT[@]} -eq 0 ] || printf '%s\0' "${INVENTORY_ROOT[@]}"; }
inventory_modules() { [ ${#INVENTORY_MODULES[@]} -eq 0 ] || printf '%s\0' "${INVENTORY_MODULES[@]}"; }

# Filter NUL-separated inventory entries on stdin, keeping walk order. A pattern
# containing "/" is matched against the whole path (like find -path), otherwise
# against the basename (-name). MODE "file" applies -type f, "any" no type test.
inventory_select() { # mode pattern...
  local mode="$1" p subj pat; shift
  while IFS= read -r -d '' p; do
    [ "$mode" = file ] && { [ -L "$p" ] && continue; [ -f "$p" ] || continue; }
    for pat in "$@"; do
      case "$pat" in */*) subj="$p" ;; *) subj="${p##*/}" ;; esac
      # shellcheck disable=SC2254  # patterns are globs by design (find -name/-path)
      case "$subj" in $pat) printf '%s\0' "$p"; break ;; esac
    done
  done
}
