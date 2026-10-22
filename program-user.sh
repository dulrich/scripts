#!/bin/bash
for _a in "$@"; do case "$_a" in --help|-h)
	printf 'usage: %s %s\n' "${0##*/}" '-[mp]|-d mysql|pgsql USER PASS'
	printf '%s\n' 'Print the SQL statements that create a database user with full rights; prints only, runs nothing.'
	exit 0;; esac; done
set -euo pipefail


opt_db='none'

while getopts ":d:mp" opt; do
	case $opt in
		d)
			opt_db="$OPTARG"
			;;
		m)
			opt_db='mysql'
			;;
		p)
			opt_db='pgsql'
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


if [ "$opt_db" = 'none' ]; then
	echo 'ERROR: must specify target db with one of -[mp] or -d mysql|pgsql'
	exit 2
fi

if [ $# -lt 2 ]; then
	echo "ERROR: missing user and pass"
	exit 3
fi

user=${1//\'/}
pass=${2//\'/\'\'}


if [ "$opt_db" = 'mysql' ]; then
echo "
CREATE USER '$user'@'localhost' IDENTIFIED BY '$pass';
GRANT ALL PRIVILEGES ON $user.* TO '$user'@'localhost'
	WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON $user.* TO '$user'@'%'
	WITH GRANT OPTION;
"
elif [ "$opt_db" = 'pgsql' ]; then
echo "
CREATE ROLE $user LOGIN ENCRYPTED PASSWORD '$pass';
GRANT ALL ON DATABASE $user TO $user;
"
else
	echo "ERROR: unknown db $opt_db"
fi
