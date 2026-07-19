#!/bin/bash
set -euo pipefail

# mysql-dump.sh: mysqldump wrapper, with optional compressed network transfer
# Copyright 2015  David Ulrich
# 
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

if [ $# -eq 0 ]; then
	echo "USAGE: ./mysql-dump.sh -h SSH_HOST -s SSH_USER -[bgr] [-[iI]] CLIENT"
	echo "LINK : ./mysql-dump.sh -[bgr] [-[iI]] -L URL"
	exit 2
fi

zip=()
unzip=()
ext=""

import=0

luser="root"
ruser="root"

host=""
suser=""
link=""

while getopts ":bgh:iIL:rs:u:U:" opt; do
	case $opt in
		b) # bzip compression
			zip=(bzip2)
			unzip=(bunzip2 -k)
			ext=".bz2"
			;;
		g) # gzip compression
			zip=(gzip -v -9)
			unzip=(gunzip)
			ext=".gz"
			;;
		h) # ssh host
			host="$OPTARG"
			;;
		i) # import mode
			import=1
			;;
		I) # import only mode
			import=2
			;;
		L)
			link="$OPTARG"
			;;
		r) # no compression
			zip=(cat)
			unzip=(cat)
			ext=""
			;;
		s) # ssh user
			suser="$OPTARG"
			;;
		u) # remote mysql user
			ruser="$OPTARG"
			;;
		U) # local mysql user
			luser="$OPTARG"
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

if [ ${#zip[@]} -eq 0 ]; then
	echo "A compression option [one of -b -g -r] is required"
	exit 1
fi

if [ $# -eq 0 ]; then
	echo "USAGE: ./mysql-dump.sh -h SSH_HOST -s SSH_USER -[bgr] [-[iI]] CLIENT"
	exit 2
fi

database=$1
output_file="$database.sql$ext"
dump=(mysqldump -u "$ruser" -p "$database")

if [ "$host" != "" ] && [ "$suser" != "" ]; then
	printf -v remote_dump '%q ' "${dump[@]}"
	printf -v remote_zip '%q ' "${zip[@]}"
	# The remote pipeline is deliberately assembled client-side from %q-escaped argv.
	# shellcheck disable=SC2029
	ssh "$suser@$host" "${remote_dump% } | ${remote_zip% }" > "$output_file"
elif [ "$link" != "" ]; then
	wget "$link" -O "$output_file"
elif [ "$import" -ne 2 ]; then
	"${dump[@]}" | "${zip[@]}" > "$output_file"
fi

if [ "$import" -gt 0 ]; then
	"${unzip[@]}" < "$output_file" | mysql -A -D "$database" -u "$luser" -p
fi
