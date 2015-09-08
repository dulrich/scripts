#!/bin/bash

# mysql-dump.sh: mysqldump wrapper, with optional compressed network transfer
# Copyright 2015  David Ulrich
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

zip=""
unzip=""
ext=""

import=0

luser="root"
ruser="root"

host=""
suser=""

while getopts ":bgh:iIrs:u:U:" opt; do
	case $opt in
		b) # bzip compression
			zip="bzip2"
			unzip="bunzip2 -k"
			ext=".bz2"
			;;
		g) # gzip compression
			zip="gzip -v -9"
			unzip="gunzip"
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
		r) # no compression
			zip="cat"
			unzip="cat"
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

shift $(($OPTIND - 1))

if [ "$zip" = "" ]; then
	echo "A compression option [one of -b -g -r] is required"
	exit 1
fi

dump="mysqldump -u \"$ruser\" -p \"$1\" | \"$zip\""

if [ "$host" != "" ] && [ "$suser" != "" ]; then
	ssh $suser@$host "eval $dump"  > $1.sql$ext
elif [ $import -ne 2 ]; then
	eval $dump > $1.sql$ext
fi

if [ $import -gt 0 ]; then
	$unzip < "$1.sql$ext" | mysql -A -D "$1" -u "$luser" -p
fi
