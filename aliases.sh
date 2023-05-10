#!/bin/bash

# aliases.sh: shorten common tasks
# Copyright 2013 - 2021  David Ulrich
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

# CONFIG VARIABLES
code_path="~/code/"
down_path="~/Downloads"
ssh_cmd="ssh"
work_user="username"
EXTERNAL_OUTPUT="DP-1-3"
INTERNAL_OUTPUT="eDP-1-1"
AUDIO_DEVICE="default" # pulse on systems using pulseaudio

here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

if [ -f $here/config.sh ] ; then
	source $here/config.sh
fi

# typing out the options every time gets old
_comp () {
	complete -o nospace -F "_$1" "$1"
}

# echo messes up some function returns
debug () {
	echo "$*" >> /tmp/debug
}

aliascd () {
	eval "
$1 () {
	cd $2/\$(defarg \"\$*\" 0 '')
}
_$1 () {
	COMPREPLY=( \$(genpath $2 \"\${COMP_WORDS[COMP_CWORD]}\") )
	return 0
}
_comp $1
	"
}

# cd aliases, eval style
cdnames=( .. ... down code )
cdpaths=( .. ../.. "$down_path" "$code_path" )

cdmax=$(( ${#cdnames[@]} - 1 ))

for (( i=0; i<=$cdmax; i++ ))
do
	aliascd ${cdnames[$i]} ${cdpaths[$i]}
done



# time tracking script
alias daylog="$here/daylog.sh"
alias dl="$here/daylog.sh"
alias dls="$here/daylog.sh -s"
wl () {
	for i in {7..1}
	do
		$here/daylog.sh -b $i
		echo ""
	done
}
dc () {
	local battery_level=$( acpi )
	$here/daylog.sh -f acpi "$battery_level"
}

# typing ./ is hard
alias lifi="$here/lifi.sh"

# defarg args which default
defarg () {
	local all=0
	local args=($1)
	local which=$2
	local def=$3

	if [ "$which" == '@' ]; then
		all=1
		which=0
	fi

	if [ ${#args[@]} -gt $which ]; then
		if [ $all -eq 1 ]; then echo "${args[@]}"
		else echo "${args[$which]}"; fi
	else
		echo $def
	fi
}

# completion generator for offset paths
genpath () {
	local cur file path cpath opath reply
	reply=()
	cpath="$1"
	opath=""
	cur="$2"

	IFS=/
	path=($cur)
	unset IFS

	if [ "${cur: -1}" == '/' ]; then
		path[${#path[@]}]=""
	fi

	file=''
	if [ ${#path[@]} -gt 0 ]; then
		file=${path[${#path[@]}-1]}
		unset path[${#path[@]}-1]
	fi

	for p in "${path[@]}"; do
		cpath="$cpath/$p"
		if [ "$opath" == "" ]; then opath="$p"
		else opath="$opath/$p"; fi
	done

	reply=( $(compgen -W "$(find $cpath -mindepth 1 -maxdepth 1 -type d -printf '%f/\t')" $file ) )

	if [ ${#reply[@]} -eq 1 ] && [ "$opath" != "" ]; then
		reply=( "$opath/${reply[0]}" )
	fi

	echo "${reply[@]}"
}

highfile () {
	local max=0
	local path=$(defarg "$*" 0 './')

	IFS=$'\n'
	local arr=( $(ls $path | grep -oP "^\d+") )
	unset IFS

	for n in "${arr[@]}"; do
		n=$((10#$n))
		((n > max)) && max=$n
	done

	echo "High: $max"
	max=$((max + 1))
	echo "Next: $max"
}

ajoin () {
	local out="$2"

	for item in "${@:3}"; do
		out="${out}${1}${item}"
	done

	echo "$out"
}


alias ll="ls -alF"
alias llr="ls -alFR"



# grep shortcuts
grep_options=( -iInR --exclude={*.d,*-bundle.js,*.map,*.min.js,*.min.css,*~,*.log,*.pyhistory} \
--exclude-dir={\
.apm,\
.deps,\
.git,\
.node-gyp,\
autom4te.cache,\
dist,\
node_modules,\
uploads,\
src-min-noconflict,\
venv\
} )



# raw grep (no excludes)
ga () {
	local path=$(defarg "$*" 1 './')

	grep -iIRP ${grep_options[@]} $1 $path
}
gac () {
	local path=$(defarg "$*" 1 './')

	grep -iIRPc ${grep_options[@]} $1 $path
}


# POSIX character classes can be a pain, especially if you forget egrep uses them
gp () {
	local path=$(defarg "$*" 1 './')

	grep -P ${grep_options[@]} $1 $path
}
gpc () {
	local path=$(defarg "$*" 1 './')

	grep -Pc ${grep_options[@]} $1 $path | grep -E ':[^0]'
}
gpw () {
	local path=$(defarg "$*" 1 './')

	grep -P ${grep_options[@]} "\b$1\b" $path
}


# shortcut for mass rewrites
rall () {
	if [ $# -lt 2 ]; then
		$2=''
	fi

	find . -type f | grep -Ev '.git|node_modules|uploads|.png|.jpg|.jpeg' | xargs -d '\n' sed -i -r -e "s/$1/$2/g"
}

# mass permission changes
dirperm () {
	local path=$(defarg "$*" 0 '.')

	find $path -type d -exec chmod 755 {} +
}

fileperm () {
	local path=$(defarg "$*" 0 '.')

	find $path -type f -exec chmod 644 {} +
}

alias pingg="ping 8.8.8.8"

mydir () {
	group=$( id -g -n $USER )

	sudo mkdir -p "$1"
	sudo chown "$USER":"$group" "$1"
}


tarc () {
	tar -zcvf "$1.tar.gz" "$1"
}
tarx () {
	tar -zxvf "$1"
}
complete -o nospace -F "_tar" "tar"


trackfix () {
	rename s/Track\ // *
	rename -v 's/^(\d)\./0$1./' *
}
trackconv () {
	local tracks=( $(ls) )

	for t in "${tracks[@]}"; do
		avconv -i "$t" "$t.mp3"
	done
}
mp3dir () {
	mkdir -p "$1-mp3"
	mv $1/*.mp3 $1-mp3/.
}


gigs () {
	local path=$(defarg "$*" 0 "/")

	du -h -t 1G $path 2> /dev/null
}


alias pow="sudo poweroff"


alias es="setxkbmap es"
alias en="setxkbmap us"

timer () {
	local MIN=$(defarg "$*" 0 1)

	for ((i=MIN*60;i>=0;i--)); do
		echo -ne "\r$(date -d"0+$i sec" +%H:%M:%S)"
		sleep 1
	done
}


alias xres="xrdb -merge $HOME/.Xresources"


external () {
    xrandr --verbose --output $EXTERNAL_OUTPUT --auto --output $INTERNAL_OUTPUT --off
	xrandr --newmode "1920x1080_60.00"  173.00  1920 2048 2248 2576  1080 1083 1088 1120 -hsync +vsync 2> /dev/null || true
    xrandr --addmode $EXTERNAL_OUTPUT 1920x1080_60.00
    xrandr --output $EXTERNAL_OUTPUT --mode "1920x1080_60.00"
}
internal () {
    xrandr --output $INTERNAL_OUTPUT --auto --output $EXTERNAL_OUTPUT --off
    xrandr --newmode "1920x1080_60.00"  173.00  1920 2048 2248 2576  1080 1083 1088 1120 -hsync +vsync 2> /dev/null || true
    xrandr --addmode $INTERNAL_OUTPUT 1920x1080_60.00
    xrandr --output $INTERNAL_OUTPUT --mode "1920x1080_60.00"
}


volume() {
	amixer -q -D $AUDIO_DEVICE sset Master $1%
}

alias gdbr="gdb -ex r"
alias gdbx="gdb -x $here/gdb.config"


# load git aliases
source $here/git-aliases.sh


if [ -f /etc/debian_version ]; then
	source $here/debian-aliases.sh
fi

if [ -f /etc/gentoo-release ]; then
	source $here/gentoo-aliases.sh
fi

if [ -f $here/work-aliases.sh ]; then
	source $here/work-aliases.sh
fi
