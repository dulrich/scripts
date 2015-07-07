# scripts

Simple utility scripts and helpful bash aliases


## aliases.sh

Defines A number of aliases and functions.

Recommended usage: add the line `source ~/scripts/aliases.sh` to `~/.bash_aliases`
or `~/.bashrc` so that `aliases.sh` will be loaded along with whatever other
local aliases you use. Alternately: run `./links.sh`, which is the same as
`ln -s ~/scripts/aliases.sh ~/.bash_aliases`

Chain-loads `git-aliases.sh` and `work-aliases.sh`


## daylog.sh

Program for tracking what was going on at a certain time, and viewing logs
from previous days.


## setting up a new machine

```bash
sudo apt-get install gmrun htop kate suckless-tools i3 vim-gtk

rm -f .vimrc && ln -s ~/scripts/vimrc .vimrc
rm -rf .vim && ln -s ~/scripts/vim .vim
```


## mysql-workbench Hotkey Fix

Edit `/usr/share/mysql-workbench/data/main_menu.xml` to update shortcut keys.


## program-user.sh

quickly create mysql user for a program with full rights, but only to its own db
`./program-user.sh program_db program_pass`


## git config
```bash
git config --global core.filemode false
git config --global push.default upstream
git config --global ui.color true
```


## Working with forked projects

`git clone git@github.com:/you/your-fork` or `git remote set-url origin git@github.com:/you/your-fork`

Track upstream: https://help.github.com/articles/syncing-a-fork then run (using aliases):
```bash
git remote add upstream git@github.com:/official/official-fork
f
u
m
```


# irc commands

See also in [irssi_startup](./irssi_startup)

* set timezone: `/script exec $ENV{'TZ'}='CST6CDT'`
* ignore junk: `/ignore * MODES JOINS PARTS QUITS`
* hide junk: `/set activity_hide_level QUITS JOINS PARTS KICKS MODES TOPIC NICKS`
* hide activity: `/set activity_hide_targets #channel`


# assorted

* multiple wine desktops `wine explorer /desktop=_NAME_,resolution=1920x1080 "/path/to/_NAME_.exe"`
* command line network swapping `nmcli con up uuid XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`
* using ssh-find-agent.sh, add `source ~/scripts/ssh-find-agent.sh` and `set_ssh_agent_socket` to `~/.bashrc`
* etherpad config file: `/opt/etherpad/local/etherpad/etherpad-lite/settings.json`


# license

Copyright 2013 - 2015  David Ulrich (http://github.com/dulrich)

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
