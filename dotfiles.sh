#!/bin/bash

# this is for detecting script's location
#here=$( dirname $( realpath "${BASH_SOURCE[0]}" ) )
here=$( pwd )


# system install
# ln -s $here/dotfiles.sh /usr/bin/dot

meta_repo=/home/fractal/code/meta_repo
meta_dotfiles=dot


meta_real_dotfiles=$( realpath $meta_repo/$meta_dotfiles )
mkdir -p $meta_real_dotfiles





help_show() {
	echo "usage: dot [-h|--help] [-a|add <file>]
	[-b|backup ?--all]
	[-l|list]
	[-p|project]
	[-r|restore <file>]
	[-s|snapshot]"
}



proj_path=$here

proj_name_list() {
	cd $meta_real_dotfiles
	#printf -- "%s\n" $( pwd )
	proj_paths=( $( find -maxdepth 1 -type d | ls ) )
	#printf -- "paths are <%s>\n" $proj_paths
	cd $here
	
	paths_max=$(( ${#proj_paths[@]} - 1 ))
	#printf -- "${#proj_paths[@]} paths"
	proj_names=()
	for (( i=0; i<=$paths_max; i++ )); do
		proj_name=${proj_paths[$i]}
		#printf -- "proj name <%s>\n" $proj_name
		proj_names+=( $proj_name )
		#printf "added proj name <%s>\n" $proj_name
	done
	echo "${proj_names[@]}"
}
#echo "real dotfiles: <$meta_real_dotfiles>"


proj_name_get() {
	# list dotfile projects
	# split path parts
	# check path segments against projects in reverse
	proj_names=( $( proj_name_list ) )
	proj_name=$( basename $here )
	names_max=$(( ${#proj_names[@]} -1 ))
	 
	for (( i=0; i<=$names_max; i++ )); do
		name=${proj_names[$i]}
		#printf "i: %d, name: <%s>, proj_name: <%s>\n" $i $name $proj_name
		if [ "$proj_name" == "$name" ]; then
			echo $proj_name
			break
		fi
	done
}
proj_name=$( proj_name_get )
#printf "project name: <%s>" $proj_name



dotfile_add() {
	filename="$1"
	
	cp $filename $meta_real_dotfiles/$proj_name/$filename
}



dotfile_backup() {
	proj_names=()
	if [ $flag_all -eq 1 ]; then
		proj_names+=( $( proj_name_list ) )
	else
		proj_names+=( $proj_name )
	fi
	#printf "project names are <%s>\n" "${proj_names[@]}"
	dirmax=$(( ${#proj_names[@]} - 1 ))
	for (( i=0; i<=$dirmax; i++ )); do
		dirname=${proj_names[$i]}
		cd $meta_real_dotfiles/$dirname 
		dot_list=( $( find -type f | ls -A ) )
		
		dotmax=$(( ${#dot_list[@]} - 1 ))
		for (( j=0; j<=$dotmax; j++ )); do
			dot=${dot_list[$j]}
			printf -- "Checking <%s/%s>..." $dirname $dot
			cp -n -u $dot $meta_real_dotfiles/$dirname/$filename 2> /dev/null
			if [ $? -eq 0 ]; then
				#printf -- "backed up <%s/%s>\n" $dirname $dot
				printf "backed up\n"
			else
				printf "ok\n"
			fi
		done
	done
	cd $here
}



dotfile_restore() {
	dotname="$1"
	
	dirname="$proj_name"
	printf -- "[%s]\n" $dirname
	cd $meta_real_dotfiles/$dirname
	dot_list=( $( find -type f | ls -A ) )
	dotmax=$(( ${#dot_list[@]} - 1 ))
	for (( j=0; j<=$dotmax; j++ )); do
		dot=${dot_list[$j]}
		if [ "$dot" == "$dotname" ]; then
			cp -n -u $dot $here/$dotname 2> /dev/null
			printf -- "Restored <%s> from <%s>\n" $dotname $meta_real_dotfiles/$dirname/$dot
			return
		fi
	done
	printf -- "ERROR: unregistered dotfile <%s>\n" $dotname
	
	cd $here
	exit 4
}



dotfiles_show() {
	proj_names=()
	if [ $flag_all -eq 1 ]; then
		proj_names+=( $( proj_name_list ) )
	else
		proj_names+=( $proj_name )
	fi
	#printf "project names are <%s>\n" "${proj_names[@]}"
	dirmax=$(( ${#proj_names[@]} - 1 ))
	for (( i=0; i<=$dirmax; i++ )); do
		dirname=${proj_names[$i]}
		printf -- "[%s]\n" $dirname
		cd $meta_real_dotfiles/$dirname 
		dot_list=( $( find -type f | ls -A ) )
		dotmax=$(( ${#dot_list[@]} - 1 ))
		for (( j=0; j<=$dotmax; j++ )); do
			dot=${dot_list[$j]}
			printf -- "* %s\n" $dot
		done
		printf -- "\n"
	done
	cd $here
}



snapshot_all() {
	cd $meta_real_dotfiles
	git add .
	git commit -m "dotfiles snapshot"
	
	# pasted from git-aliases.sh
	remotes=( $( git remote ) )
	for name in "${remotes[@]}"
	do
		push_url=$(git remote get-url --push "$name")
		if [ "$push_url" != "no_push" ]; then
			echo "Pushing to remote $name..."
			git push "$name"
		fi
	done
	cd $here
}


status_show() {
	cd $meta_real_dotfiles
	git status
	cd $here
}



project_init() {
	proj_name=$( basename $here )
	mkdir -p $meta_real_dotfiles/$proj_name
}


guard_in_project() {
	if [ "$proj_name" == "" ]; then
		printf -- "ERROR: not in a registered project\n"
		help_show
		exit 3
	fi
	
	#printf -- "project <%s>\n" $proj_name
}



flag_all=0

orig_args=()
for arg in "$@"; do
	shift
	orig_args+="$arg"
	case "$arg" in
		'--help')   set -- "$@" '-h' ;;
		'--all')    flag_all=1 ;;
		'add')      set -- "$@" '-a' ;;
		'backup')   set -- "$@" '-b' ;;
		'list')     set -- "$@" '-l' ;;
		'project')  set -- "$@" '-p' ;;
		'restore')  set -- "$@" '-r' ;;
		'snapshot') set -- "$@" '-s' ;;
		'status')   set -- "$@" '-t' ;;
		*)          set -- "$@" "$arg" ;;
	esac
done
#printf -- "flag value <%d>\n" $flag_all




while getopts ":a:r:bhlpst" opt; do
	case $opt in
		a)
			guard_in_project
			dotfile_add "$OPTARG"
			exit 0
			;;
		b)
			if [ $flag_all -eq 0 ] ; then
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
			if [ $flag_all -eq 0 ] ; then
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

shift $((OPTIND-1))

printf "Unhandled command/argument sequences\n"
exit 2







