# dirs
alias cb="cd /web/carbon"
alias cn="cd /web/carbon/node"
alias cly="cd /web/catalyst"

# remote
alias kris7="rdesktop -g $rd_res -u kris 10.10.0.15"
alias ssh1="rdesktop -g $rd_res -u Administrator -d PAWN1 10.0.1.11"
alias ssh2="rdesktop -g $rd_res -u Administrator -d PAWN1 10.0.1.12"
alias ssh3="rdesktop -g $rd_res -u Administrator -d SSH3 10.0.1.13"

alias prodweb="ssh atomic@10.10.10.101"
alias proddb="ssh atomic@10.10.10.100"
alias webweb="ssh atomic@10.10.10.102"
alias work="ssh 10.10.0.47"

alias prodmysql="mysql -A -u root -p -h 10.10.10.100"
alias workmysql="mysql -A -u root -p -h 10.10.0.47"

# node
alias nodeup="forever start /web/carbon/node/client_file_server.js ; nodemon /web/carbon/node/app_server.js"
