#!/bin/sh

# lifi.sh: easily manage license and copyright headers
# Copyright 2013 - 2015 David Ulrich
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

author="author"
lipath="licenses"
license="agplv3"
filename=""
extension="c"
mode="new"
year=$(date +%Y)

while getopts ":a:f:l:t:nu" opt; do
	case $opt in
		a)
			author="$OPTARG"
			;;
		f)
			filename="$OPTARG"
			;;
		l)
			license="$OPTARG"
			;;
		n)
			mode="new" # default
			;;
		t)
			tagline="$OPTARG"
			;;
		u)
			mode="update"
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

if [ "$filename" = "" ] ; then
	if [ "$1" != "" ] ; then
		filename="$1"
	else
		echo "Missing filename"
	fi
fi

if [ "$mode" = "new" ] ; then
	echo "// $tagline" > $filename
	echo "// Copyright $year  $author" >> $filename
	echo "//" >> $filename
	cat $lipath/$license >> $filename
else
	echo "STUB: update mode"
fi

