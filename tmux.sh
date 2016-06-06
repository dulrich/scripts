#!/bin/bash

# tmux.sh: automate standard cli setups
# Copyright 2016  David Ulrich
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

tsess () {
	local sess=""
	local path=""
	local cmds=()
	local name=()
	local nwin=0
	
	case $1 in
		chat)
			sess="chat"
			path=~
			name=( "bash" "irssi" )
			cmds=( ""     "irssi" )
			;;
		work)
			sess="work"
			path=$web_path
			name=( "carbon"          "pm2"                                                                  "gulp" )
			cmds=( "cd $path/carbon" "cd $path/carbon/node && pm2 start ../config/pm2/dev.json && pm2 logs" "cd $web_path/carbon/node && gulp" )
			;;
		:)
			echo "unknown session name"
			exit 1
		;;
	esac

	tmux has-session -t "$sess"

	if [ $? -ne 0 ]
	then
		tmux new-session -s "$sess" -n "$sess" -d
		tmux set mode-mouse on
		
		nwin=$((${#cmds[@]}-1))
		for n in $( seq $nwin -1 0 ); do
			tmux new-window -a -k -n "${name[$n]}" -t "$sess"
			tmux send-keys -t "$sess:${name[$n]}" "${cmds[$n]}" C-m
		done
		
		tmux kill-window -t "$sess:$sess"
		tmux select-window -t "$sess:${name[0]}"
	fi
	
	tmux attach -t "$sess"
}
