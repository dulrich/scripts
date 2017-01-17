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
silent=false

now_str="=== [NOW]"

while getopts ":b:cd:f:sy" opt; do
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
		s)
			silent=true
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
	local dstring=$(date -d "$2" +%Y-%m-%d)
	local prev=0
	local diff=0
	
	while read l; do
		if [ $prev -ne 0 ] ; then
			diff=$(date -d @$(( $(date -d "${l:0:8}" +%s) - $prev )) -u +%H:%M)
			
			echo "$diff"
		fi
		
		echo "${l:9}"
		
		prev=$( date -d "${l:0:8}" +%s )
	done < $fp
	
	if [ "$dstring" = "$(date +%Y-%m-%d)" ] ; then
		diff=$(date -d @$(( $(date +%s) - $prev )) -u +%H:%M)
		
		echo "$diff $now_str"
	fi
}


logpath="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/$folder/"
name=$(date -d "$dstring" +%Y-%m-%d)
now=$(date +%I:%M\ %P)
if [ $# -gt 0 ] && $newmsg ; then
	echo $now "===" "$@" >> $logpath$name.daylog
fi

if $silent ; then
	exit 0
fi

echo "[LOG FOR $name]"
if [ -f $logpath$(date -d "$dstring" +%Y-%m-%d).daylog ] ; then
	if $compute ; then
		compute_time $logpath$(date -d "$dstring" +%Y-%m-%d).daylog "$dstring"
	else
		cat $logpath$(date -d "$dstring" +%Y-%m-%d).daylog
	fi
fi

if [ "$dstring" = '' ] && ! $compute ; then
	echo "$now $now_str"
fi

exit 0
