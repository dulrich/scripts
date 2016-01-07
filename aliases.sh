#!/bin/bash

# aliases.sh: shorten common tasks
# Copyright 2013 - 2016  David Ulrich
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
rd_res="1440x1080"

code_path="/code"
data_path="/data"
script_path="~/scripts"
web_path="/web"

here=$HOME/scripts

if [ -f $here/config.sh ] ; then
	source $here/config.sh
fi

# typing out the options everytime gets old
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
cdnames=( .. code  web  data down scripts )
cdpaths=( .. "$code_path" "$web_path" "$data_path" ~/Downloads "$script_path" )

for i in {0..5}
do
	aliascd ${cdnames[$i]} ${cdpaths[$i]}
done

# Remote Desktop Shortcuts
alias rdesktop="rdesktop -g $rd_res"
alias xx="screen -x"

# time tracking script
alias daylog="$here/daylog.sh"
alias dl="$here/daylog.sh"
alias life="$here/daylog.sh -f life"
alias food="$here/daylog.sh -f food"

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

alias my="mysql -A -u root -p"
alias mykill="pkill mysql-workbench" #lol

# what find should usually do
# quote name as necessary to avoid unexpected shell-expansions
ff () {
# the shell expansion resulted in 'unknown predicate' but the expanded command works manually
# 	find . -iname \""$1"\" -not\ -path\ \"*/{.git,node_modules,uploads}/*\"
    find . -iname "$1" -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/uploads/*"
}
alias subcount="find . -type f | wc -l"

# different approach to finding files
alias lg="ll | grep -iP"
alias lgr="ll -R | grep -iP"
alias llr="ll -R"

alias lh="ls -ahlFB"

# grep shortcuts 
grep_options=( -iIR --exclude={*.min.js,*.min.css,*~} --exclude-dir={.git,node_modules,uploads,src-min-noconflict} )

# What I want grep to do 99% of the time
gr () {
	local path=$(defarg "$*" 1 './')
	
	grep ${grep_options[@]} $1 $path
}
# Sometimes I just want an overview from grep
grc () {
	local path=$(defarg "$*" 1 './')
	
	grep -c ${grep_options[@]} $1 $path | grep -E ':[^0]'
}

# raw grep (no excludes)
ga () {
	local path=$(defarg "$*" 1 './')
	
	grep -iIRP ${grep_options[@]} $1 $path
}
gac () {
	local path=$(defarg "$*" 1 './')
	
	grep -iIRPc ${grep_options[@]} $1 $path
}

# old gr / grc
ge () {
	local path=$(defarg "$*" 1 './')
	
	grep -E ${grep_options[@]} $1 $path
}
gec () {
	local path=$(defarg "$*" 1 './')
	
	grep -Ec ${grep_options[@]} $1 $path | grep -E ':[^0]'
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


## assorted
alias cl="clear"
alias cvim="cb ; vim -c vs"
alias eject_fix="sudo eject -i off"
alias fli="forever list"
flo() {
	proc=$(defarg "$*" 0 0)
	forever logs "$proc" -f
}
alias fr="forever restart"
alias fra="forever restartall"
alias fs="forever stop"
kt () {
	eval `ssh-agent`
	ssh-add
}
alias webstack="service apache2 restart && service nginx restart"
alias a2log="tail -n 50 -f /var/log/apache2/error.log"
alias phplog="tail -n 50 -f /var/log/php/php_errors.log"
alias tn="tail -n 100 -f"
alias tnn="tail -n 1000 -f"

mydir () {
    group=$( id -g -n $USER )
    
    sudo mkdir "$1"
    sudo chown "$USER":"$group" "$1"
}

tarc () {
	tar -zcvf "$1.tar.gz" "$1"
}
tarx () {
	tar -zxvf "$1"
}
complete -o nospace -F "_tar" "tar"

n() {
	local path=$(defarg "$*" 0 "server.js")

	nodemon $path
}

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

imgcp () {
	scp $* ulrichdev.com:/web/ulrichdev/static/img/.
}
gigs () {
	local path=$(defarg "$*" 0 "/")
	
	du -h -t 1G $path 2> /dev/null
}

alias pow="sudo poweroff now"
alias agi="sudo apt-get install"
alias upd="sudo apt-get update"
alias upg="sudo apt-get upgrade"
alias aar="sudo apt-add-repository"
alias es="setxkbmap es"
alias en="setxkbmap us"

timer () {
	local MIN=$(defarg "$*" 0 1)
	
	for ((i=MIN*60;i>=0;i--)); do
		echo -ne "\r$(date -d"0+$i sec" +%H:%M:%S)"
		sleep 1
	done
}


# a totally irrelevant curiosities
hashalen () {
	local len=$(defarg "$*" 0 4)
	
	printf -- '%s\n' $(git log --pretty=format:'%H' | grep -i --color=always "[[:alpha:]]\{$len\}")
}
hashstr () {
	local str=$(defarg "$*" 0 "dead")
	
	printf -- '%s\n' $(git log --pretty=format:'%H' | grep -i --color=always "$str")
}
hashwords () {
	len=$(defarg "$*" 0 4)

	dwords=$(grep "^[a-fA-F]\{$len\}$" /etc/dictionaries-common/words)
	
	echo "=============================="
	echo "searching $len letter words..."
	echo "=============================="
	
	for w in $dwords; do
		printf "\nword: $w"
		printf -- '\n\t%s' $(git log --pretty=format:'%H' | grep -i --color=always "$w")
	done
	
	echo ""
	echo "=============================="
	echo "...done"
	echo "=============================="
}
commits () {
	local terms=$( ajoin "|" "$@" )

	git log --pretty=format:"(%aN) %s" | grep -iE "($terms)"
}


# load git aliases
source $here/git-aliases.sh

# load work aliases
source $here/work-aliases.sh
