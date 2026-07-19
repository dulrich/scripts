#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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

assert_eq() {
	local expected=$1
	local actual=$2
	local label=$3

	if [[ "$actual" == "$expected" ]]; then
		ok "$label"
	else
		printf 'expected: <%s>\nactual:   <%s>\n' "$expected" "$actual" >&2
		fail "$label"
	fi
}

assert_contains() {
	local haystack=$1
	local needle=$2
	local label=$3

	if [[ "$haystack" == *"$needle"* ]]; then
		ok "$label"
	else
		printf 'missing <%s> in <%s>\n' "$needle" "$haystack" >&2
		fail "$label"
	fi
}

assert_file_content() {
	local expected=$1
	local path=$2
	local label=$3
	local actual

	actual=$(<"$path")
	assert_eq "$expected" "$actual" "$label"
}

fakebin="$fixture/fake bin"
mkdir -p "$fakebin"

cat > "$fakebin/date" <<'FAKE_DATE'
#!/bin/bash
set -euo pipefail

if [[ $# -eq 1 ]]; then
	case $1 in
		'+%Y-%m-%d') printf '2026-07-19\n'; exit 0 ;;
		'+%I:%M %P') printf '03:04 pm\n'; exit 0 ;;
		'+%s') printf '10000\n'; exit 0 ;;
	esac
fi

if [[ $# -eq 3 && $1 == -d ]]; then
	if [[ $3 == '+%Y-%m-%d' ]]; then
		case $2 in
			''|'today') printf '2026-07-19\n' ;;
			'yesterday'|'-1 days'|'2026-07-18') printf '2026-07-18\n' ;;
			*) printf '%s\n' "$2" ;;
		esac
		exit 0
	fi
	if [[ $3 == '+%s' ]]; then
		case $2 in
			'01:00 pm') printf '1000\n' ;;
			'02:30 pm') printf '6400\n' ;;
			*) exit 64 ;;
		esac
		exit 0
	fi
fi

exec /usr/bin/date "$@"
FAKE_DATE
chmod +x "$fakebin/date"

daylogs="$fixture/day logs"
mkdir -p "$daylogs"
daylog_output=$(PATH="$fakebin:$PATH" bash "$ROOT/daylog.sh" -f "$daylogs" \
	"task with spaces" 'and\backslash')
assert_eq $'[LOG FOR 2026-07-19]\n03:04 pm === task with spaces and\\backslash\n03:04 pm === [NOW]' \
	"$daylog_output" "daylog append and display format"
assert_file_content '03:04 pm === task with spaces and\backslash' \
	"$daylogs/2026-07-19.daylog" "daylog persisted line format"

silent_output=$(PATH="$fakebin:$PATH" bash "$ROOT/daylog.sh" -s -f "$daylogs" quiet)
assert_eq '' "$silent_output" "daylog silent mode"
assert_file_content $'03:04 pm === task with spaces and\\backslash\n03:04 pm === quiet' \
	"$daylogs/2026-07-19.daylog" "daylog silent mode still logs"

printf '%s\n' '01:00 pm === first' '02:30 pm === second' > "$daylogs/2026-07-19.daylog"
compute_output=$(PATH="$fakebin:$PATH" bash "$ROOT/daylog.sh" -c -f "$daylogs")
assert_eq $'[LOG FOR 2026-07-19]\n=== first\n01:30\n=== second\n01:00 === [NOW]' \
	"$compute_output" "daylog computed elapsed-time display"

printf '%s\n' '09:00 am === yesterday entry' > "$daylogs/2026-07-18.daylog"
range_output=$(PATH="$fakebin:$PATH" bash "$ROOT/daylog.sh" -b 1 -f "$daylogs")
assert_eq $'[LOG FOR 2026-07-18]\n09:00 am === yesterday entry' \
	"$range_output" "daylog relative-day display"

state="$fixture/state with spaces"
meta_repo="$state/meta repo"
projects="$state/projects"
project_one="$projects/project one"
project_two="$projects/project two"
home="$state/home"
fake_log="$state/fake-commands.log"
fake_import="$state/import.sql"
mkdir -p "$meta_repo/dot" "$project_one/nested dir" "$project_two" "$home"
: > "$fake_log"

cat > "$fakebin/_record" <<'FAKE_COMMAND'
#!/bin/bash
set -euo pipefail

command_name=${0##*/}
record=$command_name
for arg in "$@"; do
	record+="<$arg>"
done
printf '%s\n' "$record" >> "$FAKE_LOG"

case $command_name in
	git)
		if [[ ${1-} == remote && $# -eq 1 ]]; then
			printf '%s\n' origin archive
		elif [[ ${1-} == remote && ${2-} == get-url && ${3-} == --push ]]; then
			if [[ ${4-} == archive ]]; then
				printf 'no_push\n'
			else
				printf 'ssh://example.invalid/repo\n'
			fi
		elif [[ ${1-} == status ]]; then
			printf 'fixture status\n'
		fi
		;;
	mysqldump)
		printf 'DUMP DATA\n'
		;;
	gzip|bzip2|gunzip|bunzip2|cat)
		/bin/cat
		;;
	ssh)
		printf 'REMOTE DATA\n'
		;;
	wget)
		output=''
		while [[ $# -gt 0 ]]; do
			if [[ $1 == -O ]]; then
				output=$2
				shift 2
			else
				shift
			fi
		done
		printf 'DOWNLOADED DATA\n' > "$output"
		;;
	mysql|psql)
		/bin/cat > "$FAKE_IMPORT"
		;;
	sudo|useradd|usermod|groupadd|adduser|addgroup)
		exit 97
		;;
esac
FAKE_COMMAND
chmod +x "$fakebin/_record"
for command_name in git mysqldump gzip bzip2 gunzip bunzip2 cat ssh wget mysql psql \
	sudo useradd usermod groupadd adduser addgroup; do
	ln -s _record "$fakebin/$command_name"
done

run_dotfiles() {
	(
		cd "$project_one"
		DOTFILES_META_REPO="$meta_repo" FAKE_LOG="$fake_log" \
			PATH="$fakebin:$PATH" bash "$ROOT/dotfiles.sh" "$@"
	)
}

run_dotfiles project
if [[ -d "$meta_repo/dot/project one" ]]; then
	ok "dotfiles project registration"
else
	fail "dotfiles project registration"
fi

printf 'original config\n' > "$project_one/config file"
printf 'nested value\n' > "$project_one/nested dir/value"
ln -s 'config file' "$project_one/config link"
run_dotfiles add 'config file'
run_dotfiles add 'nested dir/value'
run_dotfiles add 'config link'
assert_file_content 'original config' "$meta_repo/dot/project one/config file" \
	"dotfiles add preserves spaced filename"
assert_eq 'config file' "$(readlink "$meta_repo/dot/project one/config link")" \
	"dotfiles add preserves symlink target"
assert_contains "$(<"$fake_log")" 'git<add><-f><--><project one/config file>' \
	"dotfiles add preserves git argv boundary"

printf 'updated config\n' > "$project_one/config file"
backup_output=$(run_dotfiles backup)
assert_contains "$backup_output" 'Checking <project one/config file>...backed up' \
	"dotfiles backup reports registered file"
assert_file_content 'updated config' "$meta_repo/dot/project one/config file" \
	"dotfiles backup copies project state into metadata"

rm "$project_one/config file" "$project_one/config link"
restore_output=$(run_dotfiles restore 'config file')
assert_eq $'[project one]\nRestored <config file> from <'"$meta_repo"$'/dot/project one/config file>' \
	"$restore_output" "dotfiles restore output"
assert_file_content 'updated config' "$project_one/config file" \
	"dotfiles restore recreates registered file"
run_dotfiles restore 'config link' >/dev/null
assert_eq 'config file' "$(readlink "$project_one/config link")" \
	"dotfiles restore preserves symlink identity"

printf 'local wins\n' > "$project_one/config file"
run_dotfiles restore 'config file' >/dev/null
assert_file_content 'local wins' "$project_one/config file" \
	"dotfiles restore retains no-clobber behavior"

set +e
missing_output=$(run_dotfiles restore 'not registered' 2>&1)
missing_status=$?
set -e
assert_eq '4' "$missing_status" "dotfiles missing restore exit status"
assert_contains "$missing_output" 'ERROR: unregistered dotfile <not registered>' \
	"dotfiles missing restore error format"

list_output=$(run_dotfiles list)
assert_eq $'[project one]\n* config file\n* config link\n* nested dir/value' \
	"$list_output" "dotfiles list format and ordering"

mkdir -p "$meta_repo/dot/project two"
printf 'second\n' > "$meta_repo/dot/project two/second file"
all_output=$(run_dotfiles --all list)
assert_contains "$all_output" $'[project two]\n* second file' \
	"dotfiles all-project list"

snapshot_output=$(run_dotfiles snapshot)
assert_contains "$snapshot_output" 'Pushing to remote origin...' \
	"dotfiles snapshot announces pushable remote"
fake_log_content=$(<"$fake_log")
assert_contains "$fake_log_content" 'git<push><origin>' \
	"dotfiles snapshot pushes enabled remote"
if [[ "$fake_log_content" != *'git<push><archive>'* ]]; then
	ok "dotfiles snapshot skips no_push remote"
else
	fail "dotfiles snapshot skips no_push remote"
fi
status_output=$(run_dotfiles status)
assert_eq 'fixture status' "$status_output" "dotfiles status passthrough"

printf 'old aliases\n' > "$home/.bash_aliases"
printf 'old resources\n' > "$home/.Xresources"
HOME="$home" bash "$ROOT/link.sh"
assert_eq "$ROOT/aliases.sh" "$(readlink "$home/.bash_aliases")" \
	"link installs aliases target in disposable HOME"
assert_eq "$ROOT/Xresources" "$(readlink "$home/.Xresources")" \
	"link installs Xresources target in disposable HOME"

database_dir="$state/database output"
mkdir -p "$database_dir"
: > "$fake_log"
(
	cd "$database_dir"
	FAKE_LOG="$fake_log" FAKE_IMPORT="$fake_import" PATH="$fakebin:$PATH" \
		bash "$ROOT/mysql-dump.sh" -g -i -u 'remote user' -U 'local user' 'db name'
)
assert_file_content 'DUMP DATA' "$database_dir/db name.sql.gz" \
	"mysql dump filename and compression pipeline"
database_log=$(<"$fake_log")
assert_contains "$database_log" 'mysqldump<-u><remote user><-p><db name>' \
	"mysql dump preserves mysqldump argv"
assert_contains "$database_log" 'gzip<-v><-9>' "mysql dump preserves compressor argv"
assert_contains "$database_log" 'mysql<-A><-D><db name><-u><local user><-p>' \
	"mysql import preserves mysql argv"
assert_file_content 'DUMP DATA' "$fake_import" "mysql import receives dump stream"

: > "$fake_log"
(
	cd "$database_dir"
	FAKE_LOG="$fake_log" FAKE_IMPORT="$fake_import" PATH="$fakebin:$PATH" \
		bash "$ROOT/mysql-dump.sh" -r -h 'host name' -s 'ssh user' 'remote db'
)
assert_file_content 'REMOTE DATA' "$database_dir/remote db.sql" \
	"remote dump writes expected filename"
remote_log=$(<"$fake_log")
assert_contains "$remote_log" 'ssh<ssh user@host name><mysqldump -u root -p remote\ db | cat>' \
	"remote dump preserves SSH target and escaped pipeline argv"

: > "$fake_log"
(
	cd "$database_dir"
	FAKE_LOG="$fake_log" FAKE_IMPORT="$fake_import" PATH="$fakebin:$PATH" \
		bash "$ROOT/mysql-dump.sh" -r -L 'https://example.invalid/dump' linked
)
assert_file_content 'DOWNLOADED DATA' "$database_dir/linked.sql" \
	"linked dump writes through fake downloader"
assert_contains "$(<"$fake_log")" \
	'wget<https://example.invalid/dump><-O><linked.sql>' \
	"linked dump preserves wget argv"

printf 'IMPORT ONLY\n' > "$database_dir/imported.sql"
: > "$fake_log"
(
	cd "$database_dir"
	FAKE_LOG="$fake_log" FAKE_IMPORT="$fake_import" PATH="$fakebin:$PATH" \
		bash "$ROOT/mysql-dump.sh" -r -I imported
)
assert_file_content 'IMPORT ONLY' "$fake_import" "mysql import-only mode"

set +e
no_db_output=$(bash "$ROOT/program-user.sh" 2>&1)
no_db_status=$?
missing_creds_output=$(bash "$ROOT/program-user.sh" -m only-user 2>&1)
missing_creds_status=$?
set -e
assert_eq '2' "$no_db_status" "program-user requires database exit status"
assert_eq 'ERROR: must specify target db with one of -[mp] or -d mysql|pgsql' \
	"$no_db_output" "program-user requires database output"
assert_eq '3' "$missing_creds_status" "program-user missing credentials exit status"
assert_eq 'ERROR: missing user and pass' "$missing_creds_output" \
	"program-user missing credentials output"

: > "$fake_log"
mysql_sql=$(FAKE_LOG="$fake_log" FAKE_IMPORT="$fake_import" PATH="$fakebin:$PATH" \
	bash "$ROOT/program-user.sh" -m "o'neil" "p'ass")
assert_eq $'\nCREATE USER \'oneil\'@\'localhost\' IDENTIFIED BY \'p\'\'ass\';\nGRANT ALL PRIVILEGES ON oneil.* TO \'oneil\'@\'localhost\'\n\tWITH GRANT OPTION;\nGRANT ALL PRIVILEGES ON oneil.* TO \'oneil\'@\'%\'\n\tWITH GRANT OPTION;' \
	"$mysql_sql" "program-user MySQL SQL format and quote handling"

pgsql_sql=$(FAKE_LOG="$fake_log" FAKE_IMPORT="$fake_import" PATH="$fakebin:$PATH" \
	bash "$ROOT/program-user.sh" -p app secret)
assert_eq $'\nCREATE ROLE app LOGIN ENCRYPTED PASSWORD \'secret\';\nGRANT ALL ON DATABASE app TO app;' \
	"$pgsql_sql" "program-user PostgreSQL SQL format"
unknown_output=$(FAKE_LOG="$fake_log" FAKE_IMPORT="$fake_import" PATH="$fakebin:$PATH" \
	bash "$ROOT/program-user.sh" -d sqlite app secret)
assert_eq 'ERROR: unknown db sqlite' "$unknown_output" "program-user unknown database output"
assert_eq '' "$(<"$fake_log")" \
	"program-user never invokes account, sudo, database, or network commands"

printf 'root-utils-smoke: %d/%d passed\n' "$passed" "$total"
