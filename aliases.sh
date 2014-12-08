# relative moves
..() {
	cd "../$(defarg "$*" 0 '')"
}
_..() {
	local cur file path cpath
	COMPREPLY=()
	cur="${COMP_WORDS[COMP_CWORD]}"
	
	IFS=/
	path=($cur)
	unset IFS
	
	file=''
	if [ ${#path[@]} -gt 0 ]; then
		file=${path[${#path[@]}-1]}
		unset path[${#path[@]}-1]
	fi
	
	cpath=../
	for p in "${path[@]}"; do
		cpath="$cpath/$p"
	done
	
	COMPREPLY=( $(compgen -W "$(ls $cpath)" $file ) )
	return 0
}
complete -F _.. ..

code() {
	cd "/code/$(defarg "$*" 0 '')"
}
_code() {
	local cur file path cpath
	COMPREPLY=()
	cur="${COMP_WORDS[COMP_CWORD]}"
	
	IFS=/
	path=($cur)
	unset IFS
	
	file=''
	if [ ${#path[@]} -gt 0 ]; then
		file=${path[${#path[@]}-1]}
		unset path[${#path[@]}-1]
	fi
	
	cpath=/code
	for p in "${path[@]}"; do
		cpath="$cpath/$p"
	done
	
	COMPREPLY=( $(compgen -W "$(ls $cpath)" $file ) )
	return 0
}
complete -F _code code

# helpful shortcuts
alias hh="cd /code/heirs-of-avalon"
alias down="cd ~/Downloads"
alias scripts="cd ~/scripts"

# Remote Desktop Shortcuts
rd_res="1440x1080"
alias rdesktop="rdesktop -g $rd_res"

# time tracking script
alias daylog="~/scripts/daylog.sh"
alias dl="~/scripts/daylog.sh"
alias life="~/scripts/daylog.sh -f life"
alias food="~/scripts/daylog.sh -f food"

# defarg args which default
defarg() {
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

alias my="mysql -A -u root -p"

# what find should usually do
# quote name as necessary to avoid unexpected shell-expansions
function ff {
# the shell expansion resulted in 'unknown predicate' but the expanded command works manually
# 	find . -iname \""$1"\" -not\ -path\ \"*/{.git,node_modules,uploads}/*\"
    find . -iname "$1" -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/uploads/*"
}

# What I want grep to do 99% of the time
function gr {
	local path=$(defarg "$*" 1 './')
	
	grep -EiIr --exclude={*.min.js,*.min.css,*~} --exclude-dir={.git,node_modules,uploads} $1 $path ;
}
# Sometimes I just want an overview from grep
function grc {
	local path=$(defarg "$*" 1 './')

	grep -EiIrc --exclude={*.min.js,*.min.css,*~} --exclude-dir={.git,node_modules,uploads} $1 $path | grep -E ':[^0]';
}

# shortcut for mass rewrites
function rall {
	if [ $# -lt 2 ]; then
		$2=''
	fi
	
	find . -type f | grep -Ev '.git|node_modules|uploads|.png|.jpg|.jpeg' | xargs -d '\n' sed -i -r -e "s/$1/$2/g"
}

# mass permission changes
dirperm() {
	local path=$(defarg "$*" 0 '.')

	find $path -type d -exec chmod 755 {} +
}

fileperm() {
	local path=$(defarg "$*" 0 '.')

	find $path -type f -exec chmod 644 {} +
}


function timer {
	local MIN=$1;
	
	for ((i=MIN*60;i>=0;i--)); do
		echo -ne "\r$(date -d"0+$i sec" +%H:%M:%S)";
		sleep 1;
	done
}

## assorted
alias eject_fix="sudo eject -i off"
alias fli="forever list"
alias flo="forever logs"
alias fra="forever restartall"
alias webstack="service apache2 restart && service nginx restart"
alias a2log="tail -n 50 -f /var/log/apache2/error.log"
alias phplog="tail -n 50 -f /var/log/php/php_errors.log"
alias t="tail -n 100 -f"
function n {
	local path=$(defarg "$*" 0 "server.js")

	nodemon $path
}
trackfix() {
	rename s/Track\ // *
	rename -v 's/^(\d)\./0$1./' *
}
imgcp() {
	scp $* ulrichdev.com:/web/ulrichdev/static/img/.
}
gigs() {
	local path=$(defarg "$*" 0 "/")
	
	du -h -t 1G $path 2> /dev/null
}

alias pow="sudo poweroff now"
alias upd="sudo apt-get update"
alias upg="sudo apt-get upgrade"
alias aar="sudo apt-add-repository"
alias es="setxkbmap es"
alias en="setxkbmap us"

# load git aliases
source ~/scripts/git-aliases.sh

# load work aliases
source ~/scripts/work-aliases.sh
