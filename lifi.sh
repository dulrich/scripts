#!/bin/bash

# lifi.sh: easily manage license and copyright headers
# Copyright (C) 2015 David Ulrich
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

extensions=()
prefixes=()
shebangs=()

filetype () {
	local ext="$1"
	local pre="$2"
	local sbg="$3"

	if [ "$ext" = "" ]; then
		return 1
	fi
	
	if [ "$pre" = "" ]; then
		return 2
	fi
	
	extensions+=($ext)
	prefixes+=($pre)
	shebangs+=($sbg)
}

### File types for detection
filetype "c"   "//" ""
filetype "cc"  "//" ""
filetype "cxx" "//" ""
filetype "coffee" "#" ""
filetype "h"   "//" ""
filetype "hh"  "//" ""
filetype "hs"  "--" ""
filetype "js"  "//" ""
filetype "lua" "--" ""
filetype "php" "//" ""
filetype "pl"  "#"  ""
filetype "py"  "#"  ""
filetype "sh"  "#"  "#/bin/sh"
filetype "sql" "--" ""
### End file types

author=""
tagline=""

lipath="licenses"
license="agplv3"
filename=""
extension="c"
prefix="//"
mode="new"

here=$(pwd)
year=$(date +%Y)

while getopts ":a:f:l:p:t:cnu" opt; do
	case $opt in
		a)
			author="$OPTARG"
			;;
		c)
			if [ -f $here/config.lifi ] ; then
				source $here/config.lifi
			elif [ -f $here/config/config.lifi ] ; then
				source $here/config/config.lifi
			fi
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
		p)
			prefix="$OPTARG"
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
	if [ "$tagline" != "" ] ; then
		echo "$prefix $tagline" >> $filename
	fi
	
	echo "$prefix Copyright (C) $year  $author" >> $filename
	echo "$prefix" >> $filename
	
	while read line ; do
		echo "$prefix $line" >> $filename
	done < $lipath/$license
else
	echo "STUB: update mode"
fi
