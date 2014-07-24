# relative moves
alias ..="cd .."

# helpful shortcuts
alias carbon="cd /web/carbon" # not used often
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
alias a="git add ."
function b {
	if [ $# -eq 1 ]; then
		branch=$1
	else
		branch='master'
	fi
	git checkout $branch
}
alias c="git commit -m"
alias f="git fetch upstream"
alias gls="git log --stat"
alias m="git merge upstream/master"
alias u="git pull"
alias p="git push"
alias up="git pull;git push"
alias x="git add . ; git pull"
function z { git commit -m "$1" ; git push ; }

# SSH Shortcuts
alias prodweb="ssh atomic@10.10.10.101"
alias proddb="ssh atomic@10.10.10.100"
alias work="ssh 10.10.0.47"

alias prodmysql="mysql -A -u root -p -h 10.10.10.100"
alias workmysql="mysql -A -u root -p -h 10.10.0.47"

alias my="mysql -u root -p"

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
alias fl="forever list"
alias webstack="service apache2 restart ; fuser -k 80/tcp ; service nginx restart ;"
alias a2log="tail -n 50 -f /var/log/apache2/error.log"
alias phplog="tail -n 50 -f /var/log/php/php_errors.log"

alias pow="sudo poweroff now"
alias es="setxkbmap es"
alias en="setxkbmap us"