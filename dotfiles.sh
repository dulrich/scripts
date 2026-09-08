#!/bin/bash
set -euo pipefail

# The project being managed is the caller's current directory. Its physical
# path is the project's identity: records store it, lookups compare against it.
here=$(pwd -P)

# These defaults are machine-neutral (documented in config.example.sh). Tests
# and machines with a different checkout may override them without editing
# this public file.
meta_repo=${DOTFILES_META_REPO:-$HOME/code/meta_repo}
meta_dotfiles=${DOTFILES_META_DOTFILES:-dot}

# One record per project lives here, inside the payload tree: the file name is
# the project name, its single line is the project's absolute source root. The
# leading dot keeps it out of the project listing, so the stored payload layout
# <meta_repo>/<meta_dotfiles>/<project>/<relative path> is unchanged.
projects_dir='.projects'

# Resolved during the mutation phase only. Parsing, validation and help never
# touch the filesystem, so an unusable command line creates nothing.
meta_real_dotfiles=''

help_show() {
	echo "usage: dot [-h|--help] [-a|add <file>]
	[-b|backup ?--all]
	[-l|list ?--all]
	[-m|migrate]
	[-p|project]
	[-r|restore <file>]
	[-s|snapshot]
	[-t|status]

project registers this directory's absolute path under its basename; migrate
adopts an existing payload directory of the same basename that predates the
records. Both refuse ambiguous names instead of guessing a source root.
snapshot only stages managed paths and only commits locally; publishing stays
a separate manual command.

exit codes: 1 usage, 2 unhandled arguments, 3 not in a registered project,
4 unregistered dotfile, 5 metadata repository refused, 6 registration refused,
7 restore copy failed"
}

declare -a proj_names=()
declare -a record_names=()
declare -a dot_list=()
declare -a managed_prefixed=()

# Mutation phase entry points. ensure creates the metadata directory (only the
# registering commands may); require refuses rather than creating one.
meta_ensure() {
	mkdir -p "$meta_repo/$meta_dotfiles"
	meta_real_dotfiles=$(realpath "$meta_repo/$meta_dotfiles")
}

meta_require() {
	if [[ ! -d "$meta_repo/$meta_dotfiles" ]]; then
		printf 'ERROR: no dotfiles metadata at <%s/%s>\n' "$meta_repo" "$meta_dotfiles"
		printf "Run 'dot project' inside a project to create it.\n"
		exit 5
	fi
	meta_real_dotfiles=$(realpath "$meta_repo/$meta_dotfiles")
}

meta_git() {
	(
		cd "$meta_real_dotfiles"
		git "$@"
	)
}

load_project_names() {
	mapfile -d '' -t proj_names < <(
		find "$meta_real_dotfiles" -mindepth 1 -maxdepth 1 -type d \
			! -name '.*' -printf '%f\0' |
			sort -z
	)
}

load_record_names() {
	record_names=()
	if [[ ! -d "$meta_real_dotfiles/$projects_dir" ]]; then
		return 0
	fi
	mapfile -d '' -t record_names < <(
		find "$meta_real_dotfiles/$projects_dir" -mindepth 1 -maxdepth 1 \
			-type f -printf '%f\0' |
			sort -z
	)
}

project_root_read() {
	local project_name=$1
	local record="$meta_real_dotfiles/$projects_dir/$project_name"
	local root

	if [[ ! -f "$record" ]]; then
		return 1
	fi
	IFS= read -r root < "$record" || true
	if [[ -z "$root" ]]; then
		return 1
	fi
	printf '%s\n' "$root"
}

project_record_write() {
	local project_name=$1
	local root=$2
	local record_dir="$meta_real_dotfiles/$projects_dir"

	mkdir -p "$record_dir"
	printf '%s\n' "$root" > "$record_dir/$project_name"
	meta_git add -f -- "$projects_dir/$project_name"
}

# A payload directory with no record predates the identity model.
project_is_legacy() {
	local project_name=$1

	if [[ ! -d "$meta_real_dotfiles/$project_name" ]]; then
		return 1
	fi
	if project_root_read "$project_name" >/dev/null; then
		return 1
	fi
	return 0
}

# The current project is the record whose stored root is this directory. No
# basename inference, no sibling guess.
proj_name_get() {
	local name
	local root

	load_record_names
	for name in "${record_names[@]}"; do
		root=$(project_root_read "$name") || continue
		if [[ "$root" == "$here" ]]; then
			printf '%s\n' "$name"
			return
		fi
	done
}

load_registered_entries() {
	local project_name=$1

	mapfile -d '' -t dot_list < <(
		find "$meta_real_dotfiles/$project_name" -mindepth 1 \
			\( -type f -o -type l \) -printf '%P\0' |
			sort -z
	)
}

dotfile_add() {
	local filename=$1
	local destination="$meta_real_dotfiles/$proj_name/$filename"

	mkdir -p "$(dirname "$destination")"
	cp -a --remove-destination -- "$filename" "$destination"
	meta_git add -f -- "$proj_name/$filename"
}

dotfile_backup() {
	local dirname
	local dot
	local project_path
	local source
	local destination
	local -a projects=()

	if [[ "$flag_all" -eq 1 ]]; then
		load_project_names
		projects=("${proj_names[@]}")
	else
		projects=("$proj_name")
	fi

	for dirname in "${projects[@]}"; do
		if ! project_path=$(project_root_read "$dirname"); then
			printf 'Skipped project <%s>: no registered source root\n' "$dirname"
			continue
		fi
		if [[ ! -d "$project_path" ]]; then
			printf 'Skipped project <%s>: source root <%s> is missing\n' \
				"$dirname" "$project_path"
			continue
		fi
		load_registered_entries "$dirname"
		for dot in "${dot_list[@]}"; do
			printf 'Checking <%s/%s>...' "$dirname" "$dot"
			source="$project_path/$dot"
			destination="$meta_real_dotfiles/$dirname/$dot"
			if [[ -e "$source" || -L "$source" ]]; then
				mkdir -p "$(dirname "$destination")"
				cp -a --remove-destination -- "$source" "$destination"
				printf 'backed up\n'
			else
				printf 'ok\n'
			fi
		done
	done
}

# Exactly one of restored, skipped or failed is reported per file.
dotfile_restore() {
	local dotname=$1
	local source="$meta_real_dotfiles/$proj_name/$dotname"
	local destination="$here/$dotname"
	local reason

	printf '[%s]\n' "$proj_name"
	if [[ ! -e "$source" && ! -L "$source" ]]; then
		printf 'ERROR: unregistered dotfile <%s>\n' "$dotname"
		return 4
	fi
	if [[ -e "$destination" || -L "$destination" ]]; then
		printf 'Skipped <%s>: destination exists\n' "$dotname"
		return 0
	fi
	if ! reason=$(mkdir -p "$(dirname "$destination")" 2>&1); then
		printf 'Failed <%s>: %s\n' "$dotname" "$reason"
		return 7
	fi
	if ! reason=$(cp -a -- "$source" "$destination" 2>&1); then
		printf 'Failed <%s>: %s\n' "$dotname" "$reason"
		return 7
	fi
	printf 'Restored <%s> from <%s>\n' "$dotname" "$source"
}

dotfiles_show() {
	local dirname
	local dot
	local -a projects=()

	if [[ "$flag_all" -eq 1 ]]; then
		load_project_names
		projects=("${proj_names[@]}")
	else
		projects=("$proj_name")
	fi

	for dirname in "${projects[@]}"; do
		printf '[%s]\n' "$dirname"
		load_registered_entries "$dirname"
		for dot in "${dot_list[@]}"; do
			printf '* %s\n' "$dot"
		done
		printf '\n'
	done
}

path_is_managed() {
	local path=$1
	local managed_path

	for managed_path in "${managed_prefixed[@]}"; do
		if [[ "$path" == "$managed_path" || "$path" == "$managed_path"/* ]]; then
			return 0
		fi
	done
	return 1
}

# Stage the managed paths only, commit locally, and report publication as a
# separate user action. This script never publishes.
snapshot_all() {
	local name
	local path
	local prefix
	local push_url
	local commit_output
	local -a managed=()
	local -a staged=()
	local -a unrelated=()
	local -a remotes=()
	local -a publishable=()

	load_project_names
	if [[ -d "$meta_real_dotfiles/$projects_dir" ]]; then
		managed+=("$projects_dir")
	fi
	managed+=("${proj_names[@]}")
	if [[ "${#managed[@]}" -eq 0 ]]; then
		printf 'ERROR: no managed content under <%s>\n' "$meta_real_dotfiles"
		return 5
	fi

	prefix=$(meta_git rev-parse --show-prefix)
	managed_prefixed=()
	for name in "${managed[@]}"; do
		managed_prefixed+=("$prefix$name")
	done

	mapfile -t staged < <(meta_git diff --cached --name-only)
	for path in "${staged[@]}"; do
		if ! path_is_managed "$path"; then
			unrelated+=("$path")
		fi
	done
	if [[ "${#unrelated[@]}" -gt 0 ]]; then
		printf 'ERROR: unrelated staged content in <%s>:\n' "$meta_repo"
		printf '* %s\n' "${unrelated[@]}"
		printf 'Unstage or commit it separately, then snapshot again.\n'
		return 5
	fi

	meta_git add -- "${managed[@]}"
	if ! commit_output=$(meta_git commit -m "dotfiles snapshot" 2>&1); then
		printf 'ERROR: snapshot commit failed\n'
		if [[ -n "$commit_output" ]]; then
			printf '%s\n' "$commit_output"
		fi
		return 5
	fi
	if [[ -n "$commit_output" ]]; then
		printf '%s\n' "$commit_output"
	fi
	printf 'Snapshot committed locally in <%s>.\n' "$meta_repo"

	mapfile -t remotes < <(meta_git remote)
	for name in "${remotes[@]}"; do
		push_url=$(meta_git remote get-url --push "$name")
		if [[ "$push_url" != "no_push" ]]; then
			publishable+=("$name")
		fi
	done
	if [[ "${#publishable[@]}" -eq 0 ]]; then
		printf 'No publishable remote is configured; publication stays manual.\n'
		return 0
	fi
	for name in "${publishable[@]}"; do
		printf "To publish: git -C '%s' %s %s\n" "$meta_repo" 'push' "$name"
	done
}

status_show() {
	meta_git status
}

project_init() {
	local project_name
	local existing_root
	local existing_name

	project_name=$(basename "$here")
	if existing_root=$(project_root_read "$project_name"); then
		if [[ "$existing_root" == "$here" ]]; then
			printf 'Project <%s> is already registered to <%s>\n' \
				"$project_name" "$here"
			return 0
		fi
		printf 'ERROR: project <%s> is already registered to <%s>\n' \
			"$project_name" "$existing_root"
		printf 'Refusing a second project with that name for <%s>.\n' "$here"
		return 6
	fi

	existing_name=$(proj_name_get)
	if [[ -n "$existing_name" ]]; then
		printf 'ERROR: <%s> is already registered as project <%s>\n' \
			"$here" "$existing_name"
		return 6
	fi

	if [[ -d "$meta_real_dotfiles/$project_name" ]]; then
		printf 'ERROR: unregistered legacy payload <%s/%s> exists\n' \
			"$meta_real_dotfiles" "$project_name"
		printf "Run 'dot migrate' here to adopt it.\n"
		return 6
	fi

	mkdir -p "$meta_real_dotfiles/$project_name"
	project_record_write "$project_name" "$here"
	proj_name=$project_name
	printf 'Registered project <%s> at <%s>\n' "$project_name" "$here"
}

# Adopt a payload directory that predates the records, but only when this
# directory is the unambiguous owner of that name.
project_migrate() {
	local project_name
	local existing_root
	local existing_name
	local candidate
	local -a candidates=()

	project_name=$(basename "$here")
	if existing_root=$(project_root_read "$project_name"); then
		if [[ "$existing_root" == "$here" ]]; then
			printf 'Project <%s> is already registered to <%s>\n' \
				"$project_name" "$here"
			return 0
		fi
		printf 'ERROR: ambiguous legacy project <%s>\n' "$project_name"
		printf '* registered root <%s>\n' "$existing_root"
		printf '* current root <%s>\n' "$here"
		printf 'Rename one root or its payload directory to resolve this.\n'
		return 6
	fi

	existing_name=$(proj_name_get)
	if [[ -n "$existing_name" ]]; then
		printf 'ERROR: ambiguous legacy project <%s>\n' "$project_name"
		printf '* <%s> is already registered as project <%s>\n' \
			"$here" "$existing_name"
		return 6
	fi

	load_project_names
	for candidate in "${proj_names[@]}"; do
		if [[ "$candidate" == "$project_name" ]] && project_is_legacy "$candidate"; then
			candidates+=("$candidate")
		fi
	done
	if [[ "${#candidates[@]}" -eq 0 ]]; then
		printf 'ERROR: no legacy project <%s> under <%s>\n' \
			"$project_name" "$meta_real_dotfiles"
		printf "Run 'dot project' to register a new project.\n"
		return 6
	fi
	if [[ "${#candidates[@]}" -gt 1 ]]; then
		printf 'ERROR: ambiguous legacy project <%s>; candidates:\n' "$project_name"
		printf '* %s\n' "${candidates[@]}"
		return 6
	fi

	project_record_write "$project_name" "$here"
	proj_name=$project_name
	printf 'Migrated legacy project <%s> to <%s>\n' "$project_name" "$here"
}

guard_in_project() {
	local project_name

	if [[ -n "$proj_name" ]]; then
		return 0
	fi

	project_name=$(basename "$here")
	printf 'ERROR: not in a registered project\n'
	if project_is_legacy "$project_name"; then
		printf "Legacy payload <%s/%s> has no record; run 'dot migrate' here.\n" \
			"$meta_real_dotfiles" "$project_name"
	fi
	help_show
	exit 3
}

# --- parse and validate: no filesystem writes past this point until dispatch --

flag_all=0
proj_name=''
translated_args=()
for arg in "$@"; do
	case "$arg" in
		'--help')   translated_args+=('-h') ;;
		'--all')    flag_all=1 ;;
		'add')      translated_args+=('-a') ;;
		'backup')   translated_args+=('-b') ;;
		'list')     translated_args+=('-l') ;;
		'migrate')  translated_args+=('-m') ;;
		'project')  translated_args+=('-p') ;;
		'restore')  translated_args+=('-r') ;;
		'snapshot') translated_args+=('-s') ;;
		'status')   translated_args+=('-t') ;;
		*)          translated_args+=("$arg") ;;
	esac
done
set -- "${translated_args[@]}"

command_name=''
command_arg=''
while getopts ":a:r:bhlmpst" opt; do
	case $opt in
		a)
			command_name='add'
			command_arg=$OPTARG
			;;
		b) command_name='backup' ;;
		h) command_name='help' ;;
		l) command_name='list' ;;
		m) command_name='migrate' ;;
		p) command_name='project' ;;
		r)
			command_name='restore'
			command_arg=$OPTARG
			;;
		s) command_name='snapshot' ;;
		t) command_name='status' ;;
		\?)
			echo "Invalid option: -$OPTARG"
			exit 1
			;;
		:)
			echo "Option -$OPTARG requires an argument"
			exit 1
			;;
	esac
	break
done

if [[ -z "$command_name" ]]; then
	printf 'Unhandled command/argument sequences\n'
	exit 2
fi

if [[ "$command_name" == 'help' ]]; then
	help_show
	exit 0
fi

# --- dispatch: the validated command decides what may be created ------------

case "$command_name" in
	project)
		meta_ensure
		project_init
		exit 0
		;;
	migrate)
		meta_require
		project_migrate
		exit 0
		;;
esac

meta_require
proj_name=$(proj_name_get)

case "$command_name" in
	add)
		guard_in_project
		dotfile_add "$command_arg"
		exit 0
		;;
	backup)
		if [[ "$flag_all" -eq 0 ]]; then
			guard_in_project
		fi
		dotfile_backup
		exit 0
		;;
	list)
		if [[ "$flag_all" -eq 0 ]]; then
			guard_in_project
		fi
		dotfiles_show
		exit 0
		;;
	restore)
		guard_in_project
		dotfile_restore "$command_arg"
		exit 0
		;;
	snapshot)
		snapshot_all
		exit 0
		;;
	status)
		status_show
		exit 0
		;;
esac

printf 'Unhandled command/argument sequences\n'
exit 2
