#!/bin/bash

# daylog.sh: track what happens at a certain time, and view previous logs
# Copyright 2013 - 2016 David Ulrich
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

compute=false
dstring=''
folder='logs'
newmsg=true

while getopts ":b:cd:f:y" opt; do
	case $opt in
		b)
			dstring="-$OPTARG days"
			newmsg=false
			;;
		c)
			compute=true
			;;
		d)
			dstring="$OPTARG"
			newmsg=false
			;;
		f)
			folder="$OPTARG"
			;;
		y)
			dstring='yesterday'
			newmsg=false
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


compute_time () {
	local fp="$1"
	local prev=0
	local diff=0
	
	while read l; do
		if [ $prev -ne 0 ] ; then
			diff=$(date -d @$(( $(date -d "${l:0:8}" +%s) - $prev )) -u +%H:%M)
			
			echo "$diff ${l:9}"
		fi
		
		prev=$( date -d "${l:0:8}" +%s )
	done < $fp
}


logpath="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/$folder/"
name=$(date -d "$dstring" +%Y-%m-%d)
now=$(date +%I:%M\ %P)
if [ $# -gt 0 ] && $newmsg ; then
	echo $now "===" $@ >> $logpath$name.daylog
fi

echo "[LOG FOR $name]"
if [ -f $logpath$(date -d "$dstring" +%Y-%m-%d).daylog ] ; then
	if $compute ; then
		compute_time $logpath$(date -d "$dstring" +%Y-%m-%d).daylog
	else
		cat $logpath$(date -d "$dstring" +%Y-%m-%d).daylog
	fi
fi

if [ "$dstring" = '' ] && ! $compute ; then
	echo $now "=== [NOW]"
fi

exit 0
