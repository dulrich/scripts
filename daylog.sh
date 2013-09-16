#!/bin/bash

logpath="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/logs/"

while getopts ":d:l" opt; do
	case $opt in
		d)
			echo "[LOG FOR $OPTARG]"
			cat $logpath$OPTARG.daylog
			exit 0
			;;
		l)
			cat $logpath$(date +%Y-%m-%d).daylog
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

name=$(date +%Y-%m-%d)
now=$(date +%I:%M\ %P)
if [ $# -gt 0 ]; then
	echo $now "===" $@ >> $logpath$name.daylog
fi

echo "[LOG FOR $name]"
cat $logpath$(date +%Y-%m-%d).daylog
echo $now "=== [NOW]"
