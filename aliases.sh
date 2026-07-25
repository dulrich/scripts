#!/bin/bash

# aliases.sh: shorten common tasks
# 2013 - 2024  David Ulrich
#
# CC0: This work has been marked as dedicated to the public domain. 
#
# You may have received a copy of the Creative Commons Public Domain dedication
# along with this program.  If not, see <https://creativecommons.org/publicdomain/zero/1.0/>.


export PS1='\[\033]0;\u@\h \d \t\a\]\[\033[00;36m\]\t \w \$ \[\033[00m\]'


# CONFIG VARIABLES
code_path="$HOME/code/"
down_path="$HOME/Downloads"
ssh_cmd="ssh"
work_user="username"
EXTERNAL_OUTPUT="DP-1-3"
INTERNAL_OUTPUT="eDP-1-1"
AUDIO_DEVICE="default" # pulse on systems using pulseaudio

# https://github.com/ElectricRCAircraftGuy/eRCaGuy_hello_world/blob/master/bash/get_script_path.sh
here=$(dirname "$(realpath "${BASH_SOURCE[0]}")")


if [ -f "$here/config.sh" ] ; then
	# Optional machine-local overrides are deliberately not tracked.
	# shellcheck source=/dev/null
	source "$here/config.sh"
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
	local name=$1 path_q
	printf -v path_q '%q' "$2"
	eval "
${name} () {
	local destination
	destination=\$(defarg \"\$*\" 0 '')
	cd ${path_q}/\"\$destination\"
}
_${name} () {
	COMPREPLY=( \$(genpath ${path_q} \"\${COMP_WORDS[COMP_CWORD]}\") )
	return 0
}
_comp ${name}
	"
}

# cd aliases, eval style
cdnames=( .. ... down code )
cdpaths=( .. ../.. "$down_path" "$code_path" )

cdmax=$(( ${#cdnames[@]} - 1 ))

for (( i=0; i<=cdmax; i++ ))
do
	aliascd "${cdnames[i]}" "${cdpaths[i]}"
done


unalias cl 2> /dev/null
cl () {
	local unpushed branch ghpush

	clear
	if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
		if unpushed=$(git rev-list --count '@{upstream}..HEAD' 2> /dev/null) &&
			[ "$unpushed" -gt 0 ]; then
			echo "(pushing $unpushed refs to origin)"
			git push
		else
			echo "(nothing to push)"
		fi
		# Public repos also carry a `github` remote; mirror there too.
		# Only the existence check is silenced (private repos lack it) —
		# github's own push output is shown, never swallowed.
		if git remote get-url github > /dev/null 2>&1; then
			branch=$(git rev-parse --abbrev-ref HEAD)
			ghpush=$(git rev-list --count "github/$branch..HEAD" 2> /dev/null)
			if [ -z "$ghpush" ] || [ "$ghpush" -gt 0 ]; then
				echo "(pushing ${ghpush:-all} refs to github)"
				git push github
			else
				echo "(nothing to push to github)"
			fi
		fi
		git status -bs
	else
		echo "(not a git repository)"
		ls -alF --color=auto
	fi
}


# time tracking script
# Each path is intentionally captured when the alias chain is sourced.
# shellcheck disable=SC2139
alias daylog="$here/daylog.sh"
# shellcheck disable=SC2139
alias dl="$here/daylog.sh"
# shellcheck disable=SC2139
alias dls="$here/daylog.sh -s"
wl () {
	for i in {7..1}
	do
		"$here/daylog.sh" -b "$i"
		echo ""
	done
}
dc () {
	local battery_level
	battery_level=$(acpi)
	"$here/daylog.sh" -f acpi "$battery_level"
}

# typing ./ is hard
# The resolved path is intentionally captured when the alias chain is sourced.
# shellcheck disable=SC2139
alias lifi="$here/lifi.sh"

# defarg args which default
defarg () {
	local all=0
	local -a args=()
	local which=$2
	local def=$3
	read -r -a args <<< "$1"

	if [ "$which" == '@' ]; then
		all=1
		which=0
	fi

	if [ "${#args[@]}" -gt "$which" ]; then
		if [ $all -eq 1 ]; then echo "${args[@]}"
		else echo "${args[$which]}"; fi
	else
		echo "$def"
	fi
}

# completion generator for offset paths
genpath () {
	local cur file path cpath opath reply
	reply=()
	cpath="$1"
	opath=""
	cur="$2"

	IFS=/ read -r -a path <<< "$cur"

	if [ "${cur: -1}" == '/' ]; then
		path+=("")
	fi

	file=''
	if [ ${#path[@]} -gt 0 ]; then
		file=${path[${#path[@]}-1]}
		unset 'path[${#path[@]}-1]'
	fi

	for p in "${path[@]}"; do
		cpath="$cpath/$p"
		if [ "$opath" == "" ]; then opath="$p"
		else opath="$opath/$p"; fi
	done

	mapfile -t reply < <(compgen -W "$(find "$cpath" -mindepth 1 -maxdepth 1 -type d -printf '%f/\t')" -- "$file")

	if [ "${#reply[@]}" -eq 1 ] && [ "$opath" != "" ]; then
		reply=( "$opath/${reply[0]}" )
	fi

	echo "${reply[@]}"
}

highfile () {
	local max=0
	local path name n
	path=$(defarg "$*" 0 './')

	while IFS= read -r name; do
		if [[ "$name" =~ ^([0-9]+) ]]; then
			n=$((10#${BASH_REMATCH[1]}))
			((n > max)) && max=$n
		fi
	done < <(find "$path" -mindepth 1 -maxdepth 1 -printf '%f\n')

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


alias ll="ls -alF --color=auto"
alias llr="ls -alFR --color=auto"



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
	local path
	path=$(defarg "$*" 1 './')

	grep -iIRP "${grep_options[@]}" "$1" "$path"
}
gac () {
	local path
	path=$(defarg "$*" 1 './')

	grep -iIRPc "${grep_options[@]}" "$1" "$path"
}


# POSIX character classes can be a pain, especially if you forget egrep uses them
gp () {
	local path
	path=$(defarg "$*" 1 './')

	grep -P "${grep_options[@]}" "$1" "$path"
}
gpc () {
	local path
	path=$(defarg "$*" 1 './')

	grep -Pc "${grep_options[@]}" "$1" "$path" | grep -E ':[^0]'
}
gpw () {
	local path
	path=$(defarg "$*" 1 './')

	grep -P "${grep_options[@]}" "\b$1\b" "$path"
}


# shortcut for mass rewrites
rall () {
	if [ "$#" -lt 2 ]; then
		set -- "${1:-}" ''
	fi

	find . -type f | grep -Ev '.git|node_modules|uploads|.png|.jpg|.jpeg' | xargs -d '\n' sed -i -r -e "s/$1/$2/g"
}

# mass permission changes
dirperm () {
	local path
	path=$(defarg "$*" 0 '.')

	find "$path" -type d -exec chmod 755 {} +
}

fileperm () {
	local path
	path=$(defarg "$*" 0 '.')

	find "$path" -type f -exec chmod 644 {} +
}

alias pingg="ping 8.8.8.8"

mydir () {
	local group
	group=$(id -g -n "$USER")

	sudo mkdir -p "$1"
	sudo chown "$USER":"$group" "$1"
}


movie_on () {
	xset -dpms s off
}
movie_off () {
	xset -dpms s on
}


tarc () {
	tar -zcvf "$1.tar.gz" "$1"
}
tarx () {
	tar -zxvf "$1"
}
complete -o nospace -F "_tar" "tar"


trackfix () {
	rename s/Track\ // -- *
	rename -v 's/^(\d)\./0$1./' -- *
}
trackconv () {
	local -a tracks=()
	mapfile -t tracks < <(find . -mindepth 1 -maxdepth 1 -printf '%f\n')

	for t in "${tracks[@]}"; do
		avconv -i "$t" "$t.mp3"
	done
}
mp3dir () {
	mkdir -p "$1-mp3"
	mv "$1"/*.mp3 "$1-mp3/."
}


gigs () {
	local path
	path=$(defarg "$*" 0 "/")

	du -h -t 1G "$path" 2> /dev/null
}


alias pow="sudo poweroff"


alias es="setxkbmap es"
alias en="setxkbmap us"

timer () {
	local MIN
	MIN=$(defarg "$*" 0 1)

	for ((i=MIN*60; i>=0; i--)); do
		echo -ne "\r$(date -d"0+$i sec" +%H:%M:%S)"
		sleep 1
	done
}


# HOME is intentionally captured when the alias chain is sourced.
# shellcheck disable=SC2139
alias xres="xrdb -merge $HOME/.Xresources"


external () {
    xrandr --verbose --output "$EXTERNAL_OUTPUT" --auto --output "$INTERNAL_OUTPUT" --off
	xrandr --newmode "1920x1080_60.00"  173.00  1920 2048 2248 2576  1080 1083 1088 1120 -hsync +vsync 2> /dev/null || true
    xrandr --addmode "$EXTERNAL_OUTPUT" 1920x1080_60.00
    xrandr --output "$EXTERNAL_OUTPUT" --mode "1920x1080_60.00"
}
internal () {
    xrandr --output "$INTERNAL_OUTPUT" --auto --output "$EXTERNAL_OUTPUT" --off
    xrandr --newmode "1920x1080_60.00"  173.00  1920 2048 2248 2576  1080 1083 1088 1120 -hsync +vsync 2> /dev/null || true
    xrandr --addmode "$INTERNAL_OUTPUT" 1920x1080_60.00
    xrandr --output "$INTERNAL_OUTPUT" --mode "1920x1080_60.00"
}


volume() {
	if [ "${1:-}" == "" ]; then
		amixer -D "$AUDIO_DEVICE" sget Master | grep -iIoP "\[\d+%\]" | grep -iIoP --color=never "\d+%"
	else
		amixer -q -D "$AUDIO_DEVICE" sset Master "$1%"
	fi
}
alias vol="volume"


playdir() {
	# options don't seem to work w/o interface?
	# --key-play-pause " " --key-next "d" --key-prev "a"
	cvlc --play-and-exit ./*.mp3
}

alias gdbr="gdb -ex r"
# The resolved path is intentionally captured when the alias chain is sourced.
# shellcheck disable=SC2139
alias gdbx="gdb -x $here/gdb.config"


cman() {
	man -s "2,3,3p,2x,3x,7" "$*"
}



x() {
	./build.sh
}
xd() {
	./debug.sh
}


alias size_here="du -sh .[^.]* * 2>/dev/null | sort -hr"


reload() {
	# shellcheck source=aliases.sh
	source "$here/aliases.sh"
}


# ensure bash completions are loaded
if [ -f /etc/profile.d/bash_completion.sh ]; then
	# System-provided optional completion support.
	# shellcheck source=/dev/null
	source /etc/profile.d/bash_completion.sh
fi


# load git aliases
# shellcheck source=git-aliases.sh
# The runtime-resolved sibling path works when aliases.sh is symlinked.
# shellcheck disable=SC1091
source "$here/git-aliases.sh"


# util script router: `util <command> [args]` -> util/<command>[.sh]
if [ -f "$here/util/dispatch.sh" ]; then
	# The resolved path is intentionally captured when the alias chain is sourced.
	# shellcheck disable=SC2139
	alias util="$here/util/dispatch.sh"
	if [ -f "$here/util/completions.sh" ]; then
		# shellcheck source=util/completions.sh
		# The runtime-resolved sibling path works when aliases.sh is symlinked.
		# shellcheck disable=SC1091
		source "$here/util/completions.sh"
	fi
fi


if [ -f /etc/debian_version ]; then
	# shellcheck source=debian-aliases.sh
	# The runtime-resolved sibling path works when aliases.sh is symlinked.
	# shellcheck disable=SC1091
	source "$here/debian-aliases.sh"
fi

if [ -f /etc/gentoo-release ]; then
	# shellcheck source=gentoo-aliases.sh
	# The runtime-resolved sibling path works when aliases.sh is symlinked.
	# shellcheck disable=SC1091
	source "$here/gentoo-aliases.sh"
fi

if [ -f "$here/private/aliases.sh" ]; then
	# Optional private overlay is deliberately not tracked.
	# shellcheck source=/dev/null
	source "$here/private/aliases.sh"
fi
