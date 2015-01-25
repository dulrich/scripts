#!/bin/bash

# aliases.sh: shorten common tasks
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

# relative moves
.. () {
	cd ../$(defarg "$*" 0 '')
}
_.. () {
	COMPREPLY=( $(genpath ../ "${COMP_WORDS[COMP_CWORD]}") )
	return 0
}
complete -F _.. ..

code () {
	cd /code/$(defarg "$*" 0 '')
}
_code () {
	COMPREPLY=( $(genpath /code/ "${COMP_WORDS[COMP_CWORD]}") )
	return 0
}
complete -F _code code

web () {
	cd /web/$(defarg "$*" 0 '')
}
_web () {
	COMPREPLY=( $(genpath /web/ "${COMP_WORDS[COMP_CWORD]}") )
	return 0
}
complete -F _web web

down () {
	cd ~/Downloads/$(defarg "$*" 0 '')
}
_down () {
	COMPREPLY=( $(genpath ~/Downloads/ "${COMP_WORDS[COMP_CWORD]}") )
	return 0
}
complete -F _down down

scripts () {
	cd ~/scripts/$(defarg "$*" 0 '')
}
_scripts () {
	COMPREPLY=( $(genpath ~/scripts/ "${COMP_WORDS[COMP_CWORD]}") )
	return 0
}
complete -F _scripts scripts

# helpful shortcuts
alias hh="cd /code/heirs-of-avalon"

# Remote Desktop Shortcuts
rd_res="1440x1080"
alias rdesktop="rdesktop -g $rd_res"

# time tracking script
alias daylog="~/scripts/daylog.sh"
alias dl="~/scripts/daylog.sh"
alias life="~/scripts/daylog.sh -f life"
alias food="~/scripts/daylog.sh -f food"

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
	local cur file path cpath reply
	reply=()
	cpath="$1"
	cur="$2"
	
	IFS=/
	path=($cur)
	unset IFS
	
	file=''
	if [ ${#path[@]} -gt 0 ]; then
		file=${path[${#path[@]}-1]}
		unset path[${#path[@]}-1]
	fi
	
	for p in "${path[@]}"; do
		cpath="$cpath/$p"
	done
	
	reply=( $(compgen -W "$(ls $cpath)" $file ) )
	echo "${reply[@]}"
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

# What I want grep to do 99% of the time
gr () {
	local path=$(defarg "$*" 1 './')
	
	grep -EiIR --exclude={*.min.js,*.min.css,*~} --exclude-dir={.git,node_modules,uploads} $1 $path ;
}
# Sometimes I just want an overview from grep
grc () {
	local path=$(defarg "$*" 1 './')

	grep -EiIRc --exclude={*.min.js,*.min.css,*~} --exclude-dir={.git,node_modules,uploads} $1 $path | grep -E ':[^0]';
}
# POSIX character classes can be a pain, especially if you forget egrep uses them
gp () {
	local path=$(defarg "$*" 1 './')

	grep -PiIR --exclude={*.min.js,*.min.css,*~} --exclude-dir={.git,node_modules,uploads} $1 $path ;
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
alias eject_fix="sudo eject -i off"
alias fli="forever list"
alias flo="forever logs"
alias fr="forever restart"
alias fra="forever restartall"
alias webstack="service apache2 restart && service nginx restart"
alias a2log="tail -n 50 -f /var/log/apache2/error.log"
alias phplog="tail -n 50 -f /var/log/php/php_errors.log"
alias t="tail -n 100 -f"
n() {
	local path=$(defarg "$*" 0 "server.js")

	nodemon $path
}
trackfix () {
	rename s/Track\ // *
	rename -v 's/^(\d)\./0$1./' *
}
imgcp () {
	scp $* ulrichdev.com:/web/ulrichdev/static/img/.
}
gigs () {
	local path=$(defarg "$*" 0 "/")
	
	du -h -t 1G $path 2> /dev/null
}

alias pow="sudo poweroff now"
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


# load git aliases
source ~/scripts/git-aliases.sh

# load work aliases
source ~/scripts/work-aliases.sh
