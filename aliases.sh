# helpful shortcuts
alias carbon="cd /web/carbon" # not used often
alias cb="cd /web/carbon"
alias cn="cd /web/carbon/node"
alias du="cd /web/dulrich" # not used often
alias code="cd ~/code" # not used often
alias down="cd ~/Downloads"

# Remote Desktop Shortcuts
alias rdesktop="rdesktop -g 1440x1080"

alias kris7="rdesktop -g 1440x1080 -u kris 10.10.0.15"
alias ssh1="rdesktop -g 1440x1080 -u Administrator -d PAWN1 10.0.1.11"
alias ssh2="rdesktop -g 1440x1080 -u Administrator -d PAWN1 10.0.1.12"
alias ssh3="rdesktop -g 1440x1080 -u Administrator -d PAWN1 10.0.1.13"


alias d="date"
alias fdate="date +%c" # not used often
alias cll="clear;ll" # not used often
alias cdate="clear;fdate" # not used often
alias stamp="~/stamp.sh" # not used often
alias daylog="~/scripts/daylog.sh"
alias dl="~/scripts/daylog.sh"

alias s="git status"
alias a="git add ."
alias c="git commit -m"
alias u="git pull"
alias p="git push"
alias x="git add . ; git pull"
function z { git commit -m "$1" ; git push ; }

# SSH Shortcuts
alias prodweb="ssh atomic@10.10.10.101"
alias proddb="ssh atomic@10.10.10.100"

alias my="mysql -u root -p"

function cdll { cd $1 ; ll ; } # not used often

# What you want grep to do 99% of the time
function gr {
	if [ $# -gt 1 ]; then
		path=$2
	else
		path=./
	fi
	grep -ir --exclude={*.min.js,*~} --exclude-dir=.git $1 $path ;
}
# this has been replaced by optional option 2 on gr
# function grd { grep -ir --exclude={*.min.js,*~} --exclude-dir=.git $1 $2 ; }

function timer {
	MIN=$1;
	for ((i=MIN*60;i>=0;i--)); do
		echo -ne "\r$(date -d"0+$i sec" +%H:%M:%S)";
		sleep 1;
	done
}

## 
alias webstack="service apache2 restart ; fuser -k 80/tcp ; service nginx restart ;"
alias a2log="tail -n 50 -f /var/log/apache2/error.log"
alias phplog="tail -n 50 -f /var/log/php/php_errors.log"

