#!/bin/bash


# there is a better version of this somewhere 
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
echo "we are here <$here>"

sed_files=( _build.c _build.inc.c build.sh debug.sh profiling.sh valgrind.sh )
code_file="test.c"

dest_name_code=""
dest_name_exe=""
dest_path_build="build"
dest_path_exe="./"
dest_path_root=""
dest_path_source="src"


while getopts ":b:c:e:r:s:x:" opt; do
	case $opt in
		b)
			dest_path_build="$OPTARG"
			;;
		c)
			dest_name_code="$OPTARG"
			;;
		e)
			dest_path_exe="$OPTARG"
			;;
		r)
			dest_path_root="$OPTARG"
			;;
		s)
			dest_path_source="$OPTARG"
			;;
		x)
			dest_name_exe="$OPTARG"
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


if [ "$dest_path_root" = "" ] ; then
	if [ "$1" != "" ] ; then
		dest_path_root="$1"
	else
		echo "Missing destination root path of project"
		exit 2
	fi
fi


if [ "$dest_name_code" = "" ] ; then
	if [ "$dest_name_exe" != "" ] ; then
		dest_name_code="$dest_name_exe.c"
	else
		dest_name_code=code_file
	fi
fi


if [ "$dest_name_exe" = "" ] ; then
	dest_name_exe="hworld"
fi



mkdir -p "$dest_path_root/$dest_path_source"
cp "$here/$code_file" "$dest_path_root/$dest_path_source/$dest_name_code"


mkdir -p "$dest_path_root/$dest_path_build"


for f in "${sed_files[@]}"; do
	cp "$here/$f" "$dest_path_root/$f"
done

sed -i -E -e "s;__SED_TOKEN_EXE_NAME;$dest_name_exe;" "${sed_files[@]}"
sed -i -E -e "s;__SED_TOKEN_EXE_PATH;$dest_path_exe;" "${sed_files[@]}"
sed -i -E -e "s;__SED_TOKEN_BUILD_PATH;$dest_path_build;" "${sed_files[@]}"
sed -i -E -e "s;__SED_TOKEN_SOURCE_PATH;$dest_path_source;" "${sed_files[@]}"
sed -i -E -e "s;__SED_TOKEN_CODE_NAME;$dest_name_code;" "${sed_files[@]}"


echo "._build" >> "$dest_path_root/.gitignore"
echo $( realpath --relative-to="$dest_path_root" "$dest_path_exe/$dest_name_exe" ) >> "$dest_path_root/.gitignore"
echo "$dest_path_build/*" >> "$dest_path_root/.gitignore"



