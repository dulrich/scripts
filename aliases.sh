# relative moves
function .. {
	path=..
	if [ $# -eq 1 ]; then
		path=../$1
	fi
	cd $path
}
function _.. {
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

# helpful shortcuts
alias cb="cd /web/carbon"
alias cn="cd /web/carbon/node"
alias cly="cd /web/catalyst"
alias code="cd /code" # not used often
alias down="cd ~/Downloads"
alias scripts="cd ~/scripts"

# Remote Desktop Shortcuts
alias rdesktop="rdesktop -g 1440x1080"

alias kris7="rdesktop -g 1440x1080 -u kris 10.10.0.15"
alias ssh1="rdesktop -g 1440x1080 -u Administrator -d PAWN1 10.0.1.11"
alias ssh2="rdesktop -g 1440x1080 -u Administrator -d PAWN1 10.0.1.12"
alias ssh3="rdesktop -g 1440x1080 -u Administrator -d SSH3 10.0.1.13"


alias daylog="~/scripts/daylog.sh"
alias dl="~/scripts/daylog.sh"

alias s="git status"
function a {
	if [ $# -gt 0 ]; then
		files="$@"
	else
		files='.'
	fi
	git add $files
}
function b {
	if [ $# -eq 1 ]; then
		branch=$1
	else
		branch='master'
	fi
	git checkout $branch
}
function c {
	git commit -m "$*"
}
alias d="git diff"
alias f="git fetch upstream"
alias gls="git log --stat"
alias glt="git ls-tree --abbrev HEAD"
function gx {
	chmod 755 $1
	git update-index --chmod=+x $1
}
function m {
	if [ $# -eq 1 ]; then
		branch=$1
	else
		branch='master'
	fi
	git merge $branch
}
alias u="git pull"
alias p="git push"
alias pp="git push production master"
alias up="git pull;git push"
function z {
	git commit -m "$*"
	git push
}

# SSH Shortcuts
alias prodweb="ssh atomic@10.10.10.101"
alias proddb="ssh atomic@10.10.10.100"
alias work="ssh 10.10.0.47"

alias prodmysql="mysql -A -u root -p -h 10.10.10.100"
alias workmysql="mysql -A -u root -p -h 10.10.0.47"

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
	if [ $# -gt 1 ]; then
		path=$2
	else
		path=./
	fi
	grep -EiIr --exclude={*.min.js,*.min.css,*~} --exclude-dir={.git,node_modules,uploads} $1 $path ;
}
# Sometimes I just want an overview from grep
function grc {
	if [ $# -gt 1 ]; then
		path=$2
	else
		path=./
	fi
	grep -EiIrc --exclude={*.min.js,*.min.css,*~} --exclude-dir={.git,node_modules,uploads} $1 $path | grep -E ':[^0]';
}

# shortcut for mass rewrites
function rall {
	if [ $# -lt 2 ]; then
		$2=''
	fi
	
	find . -type f | grep -Ev '.git|node_modules|uploads|.png|.jpg|.jpeg' | xargs -d '\n' sed -i -e "s/$1/$2/g"
}

function timer {
	MIN=$1;
	for ((i=MIN*60;i>=0;i--)); do
		echo -ne "\r$(date -d"0+$i sec" +%H:%M:%S)";
		sleep 1;
	done
}

## 
alias nodeup="forever start /web/carbon/node/client_file_server.js ; nodemon /web/carbon/node/app_server.js"
alias fli="forever list"
alias flo="forever logs"
alias fra="forever restartall"
alias webstack="service apache2 restart ; fuser -k 80/tcp ; service nginx restart ;"
alias a2log="tail -n 50 -f /var/log/apache2/error.log"
alias phplog="tail -n 50 -f /var/log/php/php_errors.log"
alias t='tail -n 100 -f'

alias pow="sudo poweroff now"
alias es="setxkbmap es"
alias en="setxkbmap us"

# http://stackoverflow.com/questions/342969/how-do-i-get-bash-completion-to-work-with-aliases
# git completion functions don't exist until this file is executed,
# which would normally be the first time a full git command is tab-completed
if [ -f /usr/share/bash-completion/completions/git ]; then
	source /usr/share/bash-completion/completions/git

	__git_complete a _git_add
	__git_complete b _git_checkout
	__git_complete d _git_diff
	__git_complete m _git_merge
	__git_complete p _git_push
	__git_complete u _git_pull
fi
