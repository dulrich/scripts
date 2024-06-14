#!/bin/bash

# deprecated-aliases.sh: aliases/functions that are probably unused
# 2013 - 2024  David Ulrich
#
# CC0: This work has been marked as dedicated to the public domain.
#
# You may have received a copy of the Creative Commons Public Domain dedication
# along with this program.  If not, see <https://creativecommons.org/publicdomain/zero/1.0/>.


# CONFIG VARIABLES
rd_res="1440x1080"
script_path="~/scripts"
web_path="~/code/web"

# Remote Desktop Shortcuts
alias rdesktop="rdesktop -g $rd_res"
alias xx="screen -x"

# cd aliases, eval style
cdnames=( scripts web )
cdpaths( "$script_paths" "$web_path" )

for i in {0..1}
do
	aliascd ${cdnames[$i]} ${cdpaths[$i]}
done


alias life="$here/daylog.sh -f life"
alias food="$here/daylog.sh -f food"


alias my="mysql -A -u root -p"
alias mykill="pkill mysql-workbench" #lol


# what find should usually do
# quote name as necessary to avoid unexpected shell-expansions
ff () {
	# the shell expansion resulted in 'unknown predicate' but the expanded command works manually
	# find . -iname \""$1"\" -not\ -path\ \"*/{.git,node_modules,uploads}/*\"
	find . -iname "$1" \
		-not -path "*/.deps/*" \
		-not -path "*/.git/*" \
		-not -path "*/autom4te.cache/*" \
		-not -path "*/html/scripts/*" \
		-not -path "*/node_modules/*" \
		-not -path "*/uploads/*" \
		-not -path "*/src-min-noconflict/*"
}
alias subcount="find . -type f | wc -l"


# different approach to finding files
alias lg="ll | grep -iP"
alias lgr="ll -R | grep -iP"
alias lh="ls -ahlFB"


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


# old gr / grc
ge () {
	local path=$(defarg "$*" 1 './')

	grep -E ${grep_options[@]} $1 $path
}
gec () {
	local path=$(defarg "$*" 1 './')

	grep -Ec ${grep_options[@]} $1 $path | grep -E ':[^0]'
}


pc () {
	perlcritic $1 2>/dev/null
}


## assorted
alias clim="fortune /usr/share/games/fortunes/off/limerick | cowsay -n"
alias cvim="cb ; vim -c vs"
alias eject_fix="sudo eject -i off"
alias glver="glxinfo | grep 'OpenGL version'"
kt () {
	eval `ssh-agent`
	ssh-add
}
alias webstack="service apache2 restart && service nginx restart"
alias a2log="tail -n 50 -f /var/log/apache2/error.log"
alias phplog="tail -n 50 -f /var/log/php/php_errors.log"
alias tn="tail -n 100 -f"
alias tnn="tail -n 1000 -f"


alias myips="hostname -I"


n() {
	local path=$(defarg "$*" 0 "server.js")

	nodemon $path
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


# fix common typos
alias bim="vim"
alias clera="clear"


# load tmux helper
source $here/tmux.sh

