#!/bin/bash

dstring=''
folder='logs'
newmsg=true

while getopts ":b:d:f:y" opt; do
	case $opt in
		b)
			dstring="-$OPTARG days"
			newmsg=false
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

logpath="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/$folder/"
name=$(date -d "$dstring" +%Y-%m-%d)
now=$(date +%I:%M\ %P)
if [ $# -gt 0 ] && $newmsg ; then
	echo $now "===" $@ >> $logpath$name.daylog
fi

echo "[LOG FOR $name]"
if [ -f $logpath$(date -d "$dstring" +%Y-%m-%d).daylog ]; then
	cat $logpath$(date -d "$dstring" +%Y-%m-%d).daylog
fi

if [ "$dstring" = '' ] ; then
	echo $now "=== [NOW]"
fi

exit 0
