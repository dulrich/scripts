#!/bin/bash

# work-aliases.sh: shorten common work tasks
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
