#!/usr/bin/env bash
# push-all smoke: temp repos with bare origins, a fake github remote and a stub
# publish.mjs behind a fake `bun`. Never touches the real code root or HOME.

set -u

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$test_dir/../push-all.sh"
helper="$test_dir/../lib/push.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

export HOME="$root/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset CLAUDECODE
for v in $(compgen -e CODEX_); do unset "$v"; done
mkdir -p "$HOME"

pass_count=0
fail_count=0
ok() { printf 'ok %d - %s\n' "$((pass_count + fail_count + 1))" "$1"; pass_count=$((pass_count + 1)); }
nok() { printf 'not ok %d - %s\n' "$((pass_count + fail_count + 1))" "$1" >&2; fail_count=$((fail_count + 1)); }
check() { # <description> <condition-rc>
	if [ "$2" -eq 0 ]; then ok "$1"; else nok "$1"; fi
}

# Fake `bun` runs the stub publish.mjs (a bash script) directly.
mkdir -p "$root/bin"
printf '#!/bin/bash\nexec bash "$@"\n' > "$root/bin/bun"
chmod +x "$root/bin/bun"
export PATH="$root/bin:$PATH"
calls="$root/project-calls"
: > "$calls"
cat > "$root/publish-stub.sh" <<'STUB'
#!/bin/bash
# stub publish.mjs: status | project --repo <r>
cmd=$1 r=$3
state="$r/.git/stub-projected"
case $cmd in
	status)
		src=$(git -C "$r" rev-parse master)
		if [ -f "$state" ]; then
			proj=$(cat "$state")
			lag=$(git -C "$r" rev-list --count master "^$proj")
			projj="\"$proj\""
		else
			lag=null projj=null
		fi
		pt=$(git -C "$r" rev-parse -q --verify refs/heads/public || echo null)
		pu=$(git -C "$r" rev-parse -q --verify refs/remotes/github/master || echo null)
		q() { [ "$1" = null ] && printf null || printf '"%s"' "$1"; }
		printf '{\n  "manifest": {\n    "lagCommits": 99\n  },\n  "sourceTip": "%s",\n  "projectedSource": %s,\n  "publicTip": %s,\n  "publishedTip": %s,\n  "lagCommits": %s\n}\n' \
			"$src" "$projj" "$(q "$pt")" "$(q "$pu")" "$lag" ;;
	project)
		echo "$r" >> "$STUB_CALLS"
		git -C "$r" rev-parse master > "$state"
		git -C "$r" branch -f public master ;;
esac
STUB
export STUB_CALLS="$calls"

commit() { git -C "$1" commit -q --allow-empty -m "$2"; }
# mkrepo <name> [initiative-file]: repo with INITIATIVE.md, bare origin, tracking master.
mkrepo() {
	local r="$root/code/$1"
	git init -q -b master "$r"
	[ "${2-INITIATIVE.md}" = - ] || : > "$r/${2-INITIATIVE.md}"
	git -C "$r" add -A
	commit "$r" base
	git init -q --bare -b master "$root/origins/$1.git"
	git -C "$r" remote add origin "$root/origins/$1.git"
	git -C "$r" push -q -u origin master
}
snap() { # all refs of every repo and bare remote
	for d in "$root"/code/*/ "$root"/origins/*.git "$root"/gh/*.git; do
		[ -d "$d" ] && { git -C "$d" for-each-ref; git -C "$d" rev-parse HEAD 2> /dev/null; }
	done
}
run() { PUSH_OUT=$(bash "$script" --root "$root/code" --publish-mjs "$root/publish-stub.sh" "$@" 2>&1); PUSH_RC=$?; }

mkrepo alpha
mkrepo beta INITIATIVE.md
mkrepo legacy DEVELOPMENT.md
mkrepo plain -                 # no INITIATIVE.md: out of scope
mkrepo pub
git init -q --bare -b master "$root/gh/pub.git"
git -C "$root/code/pub" remote add github "$root/gh/pub.git"
git -C "$root/code/pub" config remote.github.push refs/heads/public:refs/heads/master
echo '{}' > "$root/code/pub/.publication.json"
git init -q -b master "$root/code/noup"; : > "$root/code/noup/INITIATIVE.md"
git -C "$root/code/noup" add -A; commit "$root/code/noup" base
for r in alpha legacy plain pub; do commit "$root/code/$r" ahead1; done
commit "$root/code/alpha" ahead2
git -C "$root/code/beta" checkout -q -b side
commit "$root/code/beta" onside
git -C "$root/code/beta" checkout -q master
commit "$root/code/beta" onmaster
git -C "$root/code/beta" checkout -q side

# 1 status is read-only, lists in-scope repos, never projects
before=$(snap)
run
after=$(snap)
check 'status leaves every ref and remote unchanged' "$([ "$before" = "$after" ]; echo $?)"
check 'status never runs project' "$([ ! -s "$calls" ]; echo $?)"
check 'status exits 0 with final count' "$([ "$PUSH_RC" -eq 0 ] && [[ $PUSH_OUT == *'5 repos:'* ]]; echo $?)"
# 2 repo set
check 'non-initiative repo is skipped; legacy DEVELOPMENT.md counts' \
	"$([[ $PUSH_OUT != *plain:* && $PUSH_OUT == *legacy:\ origin\ +1* ]]; echo $?)"
# 3 no upstream
check 'repo without upstream is reported and skipped' "$([[ $PUSH_OUT == *'noup: skipped (master has no upstream)'* ]]; echo $?)"
check 'status reports projection lag without projecting' "$([[ $PUSH_OUT == *'pub: origin +1; projection lag null'* ]]; echo $?)"

# 4 refusal in an agent session
before=$(snap)
CLAUDECODE=1 run --push
check '--push refused under CLAUDECODE, nothing pushed' "$([ "$PUSH_RC" -eq 2 ] && [ "$before" = "$(snap)" ]; echo $?)"
CODEX_HOME=x run --push
check '--push refused under CODEX_*, nothing pushed' "$([ "$PUSH_RC" -eq 2 ] && [ "$before" = "$(snap)" ]; echo $?)"

# 5 --push pushes master of ahead repos (even with another branch checked out)
run --push
good=0
for r in alpha beta legacy pub; do
	[ "$(git -C "$root/code/$r" rev-parse master)" = "$(git -C "$root/origins/$r.git" rev-parse master)" ] || good=1
done
check '--push pushes master of every ahead repo, including off-master checkout' "$good"
check 'checked-out branch is left alone' "$([ "$(git -C "$root/code/beta" rev-parse --abbrev-ref HEAD)" = side ]; echo $?)"
# 6 projection only when lagging
check 'projection ran once for the lagging repo and was mirrored' \
	"$([ "$(wc -l < "$calls")" -eq 1 ] && [ "$(git -C "$root/code/pub" rev-parse public)" = "$(git -C "$root/gh/pub.git" rev-parse master)" ]; echo $?)"
run --push
check 'second sweep does not re-project when current' "$([ "$(wc -l < "$calls")" -eq 1 ] && [ "$PUSH_RC" -eq 0 ]; echo $?)"
commit "$root/code/pub" more
run --push
check 'new master commit makes the projection rebuild again' "$([ "$(wc -l < "$calls")" -eq 2 ]; echo $?)"

# 7 one failing repo does not stop the sweep; exit non-zero
git clone -q "$root/origins/alpha.git" "$root/other"
commit "$root/other" diverge
git -C "$root/other" push -q origin HEAD:master
commit "$root/code/alpha" local-only
commit "$root/code/legacy" fresh
run --push
check 'rejected repo is FAILED, sweep continues, exit non-zero' \
	"$([ "$PUSH_RC" -eq 1 ] && [[ $PUSH_OUT == *'alpha: FAILED'* ]] && [ "$(git -C "$root/code/legacy" rev-parse master)" = "$(git -C "$root/origins/legacy.git" rev-parse master)" ]; echo $?)"

# 8 pure helper
# shellcheck source=util/lib/push.sh
. "$helper"
j() { printf '{\n  "manifest": {"lagCommits": 9},\n  "projectedSource": %s,\n  "lagCommits": %s\n}\n' "$1" "$2"; }
res=
_push_needs_projection "$(j '"abc"' 0)" && res+=a
_push_needs_projection "$(j '"abc"' 2)" && res+=b
_push_needs_projection "$(j null null)" && res+=c
_push_needs_projection "$(j '"abc"' null)" && res+=d
check 'needs-projection only on lag, null lag or no projection' "$([ "$res" = bcd ]; echo $?)"

printf '%d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
