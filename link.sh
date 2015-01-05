# daylog.sh: track what happens at a certain time, and view previous logs
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

# link .bash_aliases to the repo aliases file
rm ~/.bash_aliases
ln -s ~/scripts/aliases.sh ~/.bash_aliases

# link irssi scripts into the repo
mkdir -p ~/.irssi
rm ~/.irssi/scripts
ln -s ~/scripts/irssi_scripts ~/.irssi/scripts
