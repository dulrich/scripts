#!/bin/bash
set -euo pipefail

# The project being managed is the caller's current directory.
here=$(pwd)

# These defaults retain the historical metadata layout. Tests and machines with a
# different checkout may override the repository without editing this public file.
meta_repo=${DOTFILES_META_REPO:-/home/fractal/code/meta_repo}
meta_dotfiles=${DOTFILES_META_DOTFILES:-dot}

mkdir -p "$meta_repo/$meta_dotfiles"
meta_real_dotfiles=$(realpath "$meta_repo/$meta_dotfiles")

help_show() {
	echo "usage: dot [-h|--help] [-a|add <file>]
	[-b|backup ?--all]
	[-l|list]
	[-p|project]
	[-r|restore <file>]
	[-s|snapshot]"
}

declare -a proj_names=()
declare -a dot_list=()

load_project_names() {
	mapfile -d '' -t proj_names < <(
		find "$meta_real_dotfiles" -mindepth 1 -maxdepth 1 -type d \
			! -name '.*' -printf '%f\0' |
			sort -z
	)
}

proj_name_get() {
	local current_name
	local name

	current_name=$(basename "$here")
	load_project_names
	for name in "${proj_names[@]}"; do
		if [[ "$current_name" == "$name" ]]; then
			printf '%s\n' "$current_name"
			return
		fi
	done
}

proj_name=$(proj_name_get)

load_registered_entries() {
	local project_name=$1

	mapfile -d '' -t dot_list < <(
		find "$meta_real_dotfiles/$project_name" -mindepth 1 \
			\( -type f -o -type l \) -printf '%P\0' |
			sort -z
	)
}

project_path_for_name() {
	local project_name=$1

	if [[ "$project_name" == "$(basename "$here")" ]]; then
		printf '%s\n' "$here"
	else
		printf '%s/%s\n' "$(dirname "$here")" "$project_name"
	fi
}

dotfile_add() {
	local filename=$1
	local destination="$meta_real_dotfiles/$proj_name/$filename"

	mkdir -p "$(dirname "$destination")"
	cp -a --remove-destination -- "$filename" "$destination"
	(
		cd "$meta_real_dotfiles"
		git add -f -- "$proj_name/$filename"
	)
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
		project_path=$(project_path_for_name "$dirname")
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

dotfile_restore() {
	local dotname=$1
	local source="$meta_real_dotfiles/$proj_name/$dotname"
	local destination="$here/$dotname"

	printf '[%s]\n' "$proj_name"
	if [[ -e "$source" || -L "$source" ]]; then
		mkdir -p "$(dirname "$destination")"
		if [[ ! -e "$destination" && ! -L "$destination" ]]; then
			cp -a -- "$source" "$destination"
		fi
		printf 'Restored <%s> from <%s>\n' "$dotname" "$source"
		return
	fi

	printf 'ERROR: unregistered dotfile <%s>\n' "$dotname"
	return 4
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

snapshot_all() {
	local name
	local push_url
	local -a remotes=()

	(
		cd "$meta_real_dotfiles"
		git add .
		git commit -m "dotfiles snapshot"
		mapfile -t remotes < <(git remote)
		for name in "${remotes[@]}"; do
			push_url=$(git remote get-url --push "$name")
			if [[ "$push_url" != "no_push" ]]; then
				echo "Pushing to remote $name..."
				git push "$name"
			fi
		done
	)
}

status_show() {
	(
		cd "$meta_real_dotfiles"
		git status
	)
}

project_init() {
	proj_name=$(basename "$here")
	mkdir -p "$meta_real_dotfiles/$proj_name"
}

guard_in_project() {
	if [[ -z "$proj_name" ]]; then
		printf 'ERROR: not in a registered project\n'
		help_show
		exit 3
	fi
}

flag_all=0
translated_args=()
for arg in "$@"; do
	case "$arg" in
		'--help')   translated_args+=('-h') ;;
		'--all')    flag_all=1 ;;
		'add')      translated_args+=('-a') ;;
		'backup')   translated_args+=('-b') ;;
		'list')     translated_args+=('-l') ;;
		'project')  translated_args+=('-p') ;;
		'restore')  translated_args+=('-r') ;;
		'snapshot') translated_args+=('-s') ;;
		'status')   translated_args+=('-t') ;;
		*)          translated_args+=("$arg") ;;
	esac
done
set -- "${translated_args[@]}"

while getopts ":a:r:bhlpst" opt; do
	case $opt in
		a)
			guard_in_project
			dotfile_add "$OPTARG"
			exit 0
			;;
		b)
			if [[ "$flag_all" -eq 0 ]]; then
				guard_in_project
			fi
			dotfile_backup
			exit 0
			;;
		h)
			help_show
			exit 0
			;;
		l)
			if [[ "$flag_all" -eq 0 ]]; then
				guard_in_project
			fi
			dotfiles_show
			exit 0
			;;
		p)
			project_init
			exit 0
			;;
		r)
			guard_in_project
			dotfile_restore "$OPTARG"
			exit 0
			;;
		s)
			snapshot_all
			exit 0
			;;
		t)
			status_show
			exit 0
			;;
		\?)
			echo "Invalid option: -$OPTARG"
			exit 1
			;;
		:)
			echo "Option -$OPTARG requires an argument"
			exit 1
			;;
	esac
done

shift "$((OPTIND - 1))"

printf 'Unhandled command/argument sequences\n'
exit 2
