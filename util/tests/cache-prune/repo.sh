# shellcheck shell=bash
#
# Repo suite: the `repo` runtime -- fleet-repository residue measurement
# (../../cache-prune/adapters.sh), its RT_DETAIL breakdown seam
# (../../cache-prune.sh) and its guarded purge verb
# (../../cache-prune/actions.sh).
#
# Sourced by ../cache-prune.sh, the canonical test entry point, which owns
# the harness (ok/bad/assert_*), the fixture sandbox and the command
# doubles every assertion here relies on. Not runnable on its own.
#
# Everything below runs against a synthetic fleet root built under that
# sandbox: two `git init` repositories in a tmpdir, never a real repository
# and never the real /home/_shared_code. The purge assertions delete files
# for real (that is the point of testing a verb whose implementation is
# `rm -rf`), so the fixture is built fresh here and every destructive case
# runs last, after the read-only ones have measured it.
# shellcheck disable=SC1091,SC2317,SC2034

REPO_FLEET="$SANDBOX/repo-fleet"
REPO_STUB="$SANDBOX/repo-stub-closeout.mjs"
REPO_ESCAPE_TARGET="$SANDBOX/repo-escape-target"
REPO_ALPHA="$REPO_FLEET/alpha"
REPO_ORPHAN_DIR="$REPO_ALPHA/.claude/worktrees/orphan"
REPO_LIVE_DIR="$REPO_ALPHA/.claude/worktrees/live"
REPO_SPIKE_SCRATCH="$REPO_ALPHA/runs/spike/scratch"
REPO_SPIKE_TRACKED="$REPO_ALPHA/runs/spike/tracked.txt"
REPO_SPIKE_ESCAPE="$REPO_ALPHA/runs/spike/escape"
REPO_DISPATCH_FILE="$REPO_ALPHA/runs/dispatch/fixture-slug-wp-1-brief.md"

# Identity and signing pinned per-invocation rather than written into the
# fixture's config, so the suite cannot depend on (or disturb) the running
# user's git configuration.
repo_git() {
    git -C "$1" \
        -c user.email=cache-prune@example.invalid \
        -c user.name='cache-prune test' \
        -c commit.gpgsign=false \
        "${@:2}"
}

# repo_du_sum: the same `du -sb` the adapter uses, summed over an explicit
# path list -- so the expected byte counts below are derived from the fixture
# paths this suite created, independently of how the adapter enumerates them.
repo_du_sum() {
    local total=0 path bytes

    for path in "$@"; do
        bytes=$(du -sb -- "$path" 2>/dev/null | awk 'NR == 1 { print $1 }') || bytes=0
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        total=$((total + bytes))
    done

    printf '%s\n' "$total"
}

repo_paths_exist() {
    local path

    for path in "$@"; do
        [[ -e "$path" ]] || return 1
    done
}

# --- fixture fleet -------------------------------------------------------
#
#   alpha/                      a repository, with every bucket populated
#     .claude/worktrees/live      a real linked worktree (git knows it)
#     .claude/worktrees/orphan    bucket (a): git does not know it
#     runs/spike/scratch          bucket (b)
#     runs/spike/tracked.txt      bucket (b), but git-tracked -> never purged
#     runs/spike/escape           bucket (b), but a symlink out of the repo
#     runs/dispatch/              bucket (c), via the stub below
#     tool/runs/dispatch/         bucket (c) again: the find is recursive
#     nested-repo/                a repository, but not a direct child of the
#                                 fleet root -- never a fleet repo
#   beta/                       a repository with no residue at all
#   not-a-repo/                 a directory without .git -- never enumerated
mkdir -p "$REPO_FLEET/not-a-repo" "$REPO_ESCAPE_TARGET"
git init -q "$REPO_ALPHA"
git init -q "$REPO_FLEET/beta"
git init -q "$REPO_ALPHA/nested-repo"

mkdir -p "$REPO_ORPHAN_DIR" "$REPO_SPIKE_SCRATCH" \
    "$REPO_ALPHA/runs/dispatch" "$REPO_ALPHA/tool/runs/dispatch"
head -c 8192 /dev/zero > "$REPO_ORPHAN_DIR/stale-build.bin"
head -c 4096 /dev/zero > "$REPO_SPIKE_SCRATCH/scratch.bin"
head -c 2048 /dev/zero > "$REPO_ESCAPE_TARGET/payload.bin"
ln -s "$REPO_ESCAPE_TARGET" "$REPO_SPIKE_ESCAPE"
printf 'tracked spike scratch\n' > "$REPO_SPIKE_TRACKED"
printf 'brief\n' > "$REPO_DISPATCH_FILE"
printf 'seed\n' > "$REPO_ALPHA/seed.txt"
repo_git "$REPO_ALPHA" add seed.txt runs/spike/tracked.txt
repo_git "$REPO_ALPHA" commit -q -m 'fixture seed'
repo_git "$REPO_ALPHA" worktree add -q -b live-branch "$REPO_LIVE_DIR"

# Stub runs-closeout.mjs: fixed --report-json output, so bucket (c) has an
# exact expected size and no real closeout script is ever invoked. The
# `unclassified` row is deliberately the largest one -- if the adapter ever
# starts counting rows it cannot name, the bucket total moves by 9999 bytes
# and this suite fails loudly.
cat > "$REPO_STUB" <<'STUBEOF'
process.stdout.write(
  JSON.stringify({
    unit: "fixture",
    dispatchDir: process.argv[process.argv.indexOf("--dispatch-dir") + 1],
    implementedSlugs: ["fixture-slug"],
    files: [
      { path: "/fixture/fixture-slug-wp-1-brief.md", bytes: 1000, slug: "fixture-slug", class: "archive-md" },
      { path: "/fixture/fixture-slug-wp-1-prompt.txt", bytes: 200, slug: "fixture-slug", class: "archive-txt" },
      { path: "/fixture/fixture-slug-wp-1.status", bytes: 34, slug: "fixture-slug", class: "delete-only" },
      { path: "/fixture/fixture-slug-notes.bin", bytes: 9999, slug: "fixture-slug", class: "unclassified" },
    ],
  }) + "\n",
);
STUBEOF

REPO_EXPECT_ORPHAN=$(repo_du_sum "$REPO_ORPHAN_DIR")
REPO_EXPECT_SPIKE=$(repo_du_sum "$REPO_SPIKE_SCRATCH" "$REPO_SPIKE_TRACKED" "$REPO_SPIKE_ESCAPE")
# 1000 + 200 + 34 counted classes, times the two dispatch directories; the
# 9999-byte unclassified row is never counted.
REPO_EXPECT_DISPATCH=2468
REPO_EXPECT_RECLAIM=$((REPO_EXPECT_ORPHAN + REPO_EXPECT_SPIKE))
REPO_EXPECT_TOTAL=$((REPO_EXPECT_RECLAIM + REPO_EXPECT_DISPATCH))

CACHE_PRUNE_REPO_ROOT="$REPO_FLEET"
CACHE_PRUNE_RUNS_CLOSEOUT="$REPO_STUB"


echo "[repo detect] the fleet root decides, and only direct children with .git are repositories"
all_present
reset_logs
CACHE_PRUNE_REPO_ROOT="$SANDBOX/no-such-fleet-root"
assert_failure "repo is not detected when the fleet root is absent" rt_repo_detect
assert_eq "unavailable 0 0 -" "$(rt_repo_size "")" "an absent fleet root probes unavailable, not zero"
CACHE_PRUNE_REPO_ROOT="$REPO_FLEET"
assert_success "repo is detected when the fleet root exists" rt_repo_detect
# The nested repository, the linked worktree and the .git-less directory are
# all under the root; none of them is a fleet repository (cycle-2 E1).
assert_eq "$REPO_ALPHA
$REPO_FLEET/beta" "$(rt_repo_roots)" "only direct child directories containing .git are enumerated"


echo "[repo buckets] an orphaned worktree is a candidate, a live one never is"
assert_eq "$REPO_ORPHAN_DIR" "$(rt_repo_orphan_worktrees "$REPO_ALPHA")" "only the worktree git no longer lists is a candidate"
assert_contains "$(rt_repo_live_worktrees "$REPO_ALPHA")" "$(realpath "$REPO_LIVE_DIR")" "git still lists the live worktree"
assert_eq "0" "$(rt_repo_orphan_worktrees "$REPO_FLEET/beta" | wc -c)" "a repository with no worktrees dir yields no candidates"


echo "[repo probe] the size adapter returns exactly one well-formed record and no prose"
repo_record="$(rt_repo_size "")"
assert_eq "1" "$(printf '%s\n' "$repo_record" | wc -l)" "the adapter emits exactly one line"
assert_success "the record is well-formed" probe_is_valid "$repo_record"
assert_eq "available $REPO_EXPECT_TOTAL $REPO_EXPECT_RECLAIM repo" "$repo_record" "total is (a)+(b)+(c), reclaimable is (a)+(b) only"


echo "[repo detail] the RT_DETAIL seam prints the three buckets separately, under the size line"
all_present
reset_logs
FAILED=0
TOTAL_BYTES=0
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0
MODE="report"
INCLUDE_PURGE=false
REPO_REPORT_FILE="$SANDBOX/repo-report.log"
: > "$REPO_REPORT_FILE"
process_runtime repo >"$REPO_REPORT_FILE" 2>&1 || true
repo_report="$(cat "$REPO_REPORT_FILE")"
assert_eq "rt_repo_detail" "${RT_DETAIL[repo]}" "repo is the runtime carrying a detail seam"
assert_contains "$repo_report" "repo cache size: $(human_bytes "$REPO_EXPECT_TOTAL") total ($REPO_EXPECT_TOTAL bytes)" "the runtime's own size line still reports the aggregate"
assert_contains "$repo_report" "repo orphaned worktrees: $(human_bytes "$REPO_EXPECT_ORPHAN") ($REPO_EXPECT_ORPHAN bytes, 1 dirs) -- purge tier" "bucket (a) is printed with its own byte count and dir count"
assert_contains "$repo_report" "repo spike scratch: $(human_bytes "$REPO_EXPECT_SPIKE") ($REPO_EXPECT_SPIKE bytes) -- purge tier" "bucket (b) is printed with its own byte count"
assert_contains "$repo_report" "repo implemented dispatch records: $(human_bytes "$REPO_EXPECT_DISPATCH") ($REPO_EXPECT_DISPATCH bytes) -- archive with runs-closeout.mjs --slug <s> --dispatch-dir <d> --apply; never deleted here" "bucket (c) is printed as archive-not-delete, pointing at the closeout CLI"
assert_contains "$repo_report" "repo reclaimable via the purge verb ($(human_bytes "$REPO_EXPECT_RECLAIM"), $REPO_EXPECT_RECLAIM bytes) -- requires --include-purge" "only (a)+(b) are offered as reclaimable"


echo "[repo --report] reports every bucket and deletes nothing"
assert_success "--report leaves the orphaned worktree, the spike scratch and the dispatch record in place" \
    repo_paths_exist "$REPO_ORPHAN_DIR" "$REPO_SPIKE_SCRATCH" "$REPO_SPIKE_TRACKED" "$REPO_SPIKE_ESCAPE" "$REPO_DISPATCH_FILE" "$REPO_LIVE_DIR"
assert_eq "" "$MUTATE_LOG" "--report performs no mutating call for repo either"


echo "[repo --yes] bare --yes never touches repo -- it is opt-in, with no safe verb"
all_present
reset_logs
FAILED=0
MODE="yes"
INCLUDE_PURGE=false
REPO_YES_FILE="$SANDBOX/repo-yes.log"
: > "$REPO_YES_FILE"
process_runtime repo >"$REPO_YES_FILE" 2>&1 || true
assert_contains "$(cat "$REPO_YES_FILE")" "repo: skipped." "repo is skipped under bare --yes"
assert_success "bare --yes deletes nothing" \
    repo_paths_exist "$REPO_ORPHAN_DIR" "$REPO_SPIKE_SCRATCH" "$REPO_SPIKE_ESCAPE" "$REPO_DISPATCH_FILE"
assert_eq "" "${RT_PRUNE[repo]+set}" "repo intentionally has no safe-verb registry entry"


echo "[repo bucket (c)] an absent runs-closeout.mjs makes only that bucket unavailable"
all_present
reset_logs
CACHE_PRUNE_RUNS_CLOSEOUT="$SANDBOX/no-such-runs-closeout.mjs"
repo_record_nostub="$(rt_repo_size "")"
assert_success "the record stays well-formed without the closeout script" probe_is_valid "$repo_record_nostub"
assert_eq "available $REPO_EXPECT_RECLAIM $REPO_EXPECT_RECLAIM repo" "$repo_record_nostub" "(a)+(b) are still measured; (c) is excluded from the total, not guessed"
assert_contains "$(rt_repo_detail)" "repo implemented dispatch records: unavailable (runs-closeout.mjs missing or failed)" "bucket (c) reports itself unavailable by name"
REPO_MAIN_FILE="$SANDBOX/repo-main-report.log"
: > "$REPO_MAIN_FILE"
set +e
( main --report >"$REPO_MAIN_FILE" 2>&1 )
repo_main_status=$?
set -e
assert_eq "0" "$repo_main_status" "a full --report run still exits 0 with bucket (c) unavailable"
assert_contains "$(cat "$REPO_MAIN_FILE")" "==== repo ====" "the repo section is part of a full --report run"
CACHE_PRUNE_RUNS_CLOSEOUT="$REPO_STUB"


echo "[repo --yes --include-purge] removes (a) and (b), never (c) and never a live worktree"
all_present
reset_logs
FAILED=0
MODE="yes"
INCLUDE_PURGE=true
REPO_PURGE_FILE="$SANDBOX/repo-purge.log"
: > "$REPO_PURGE_FILE"
process_runtime repo >"$REPO_PURGE_FILE" 2>&1 || true
repo_purge_output="$(cat "$REPO_PURGE_FILE")"
MODE="report"
INCLUDE_PURGE=false
assert_failure "the orphaned worktree is removed" test -e "$REPO_ORPHAN_DIR"
assert_failure "the spike scratch tree is removed" test -e "$REPO_SPIKE_SCRATCH"
assert_success "the live worktree and the dispatch record survive" \
    repo_paths_exist "$REPO_LIVE_DIR" "$REPO_DISPATCH_FILE" "$REPO_ALPHA/tool/runs/dispatch"
assert_contains "$repo_purge_output" "repo: prune complete." "the purge verb reports completion"
assert_eq "0" "$FAILED" "a purge with skipped paths is not a failure"


echo "[repo purge guard] a spike entry whose realpath leaves the repository is refused"
assert_success "the escaping symlink and its target outside the fleet root are untouched" \
    repo_paths_exist "$REPO_SPIKE_ESCAPE" "$REPO_ESCAPE_TARGET/payload.bin"
assert_contains "$repo_purge_output" "note: skipped $REPO_SPIKE_ESCAPE (guard: realpath" "the containment guard names itself in a note line"


echo "[repo purge guard] a git-tracked spike entry is refused"
assert_success "the tracked spike file survives the purge" repo_paths_exist "$REPO_SPIKE_TRACKED"
assert_contains "$repo_purge_output" "note: skipped $REPO_SPIKE_TRACKED (guard: git-tracked)" "the tracked-path guard names itself in a note line"

# Hand the harness's empty sandbox root back to anything sourced after this
# suite: nothing else here may reach the fixture fleet, let alone a real one.
CACHE_PRUNE_REPO_ROOT="$SANDBOX/empty-fleet-root"
CACHE_PRUNE_RUNS_CLOSEOUT="$SANDBOX/absent-runs-closeout.mjs"
