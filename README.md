# scripts

Simple utility scripts and helpful bash aliases


## aliases.sh

Defines a number of aliases and functions.

Recommended usage: add the line `source ~/scripts/aliases.sh` to `~/.bash_aliases`
or `~/.bashrc` so that `aliases.sh` will be loaded along with whatever other
local aliases you use. Alternately: run `./links.sh`, which is the same as
`ln -s ~/scripts/aliases.sh ~/.bash_aliases`

Chain-loads `git-aliases.sh`


## daylog.sh

Program for tracking what was going on at a certain time, and viewing logs
from previous days.


## crouton setup commands
```bash
ctrl+alt+t
shell
sh ~/Downloads/crouton
sudo sh ~/Downloads/crouton -r trusty -t lxde cli-extra extension keyboard
sudo enter-chroot
xinit
```


## setting up a new machine

```bash
sudo apt-get install gmrun htop curl git ssh mosh suckless-tools i3 vim-gtk bash-completion xrvt-unicode

#clone scripts repo

rm -f .vimrc && ln -s ~/scripts/vimrc .vimrc
rm -rf .vim && ln -s ~/scripts/vim .vim

cd ~/.vim/bundle
git clone https://github.com/othree/html5.vim
git clone https://github.com/scrooloose/nerdcommenter.git

ln -s ~/scripts/aliases.sh ~/.bash_aliases
ln -s ~/scripts/i3 .i3
xrdb ~/.Xresources

#crouton, alternate aliases
ln -s ~/scripts/crouton/crouton_aliases.sh ~/.bash_aliases

#crouton, remap search key to mod4
ln -s ~/scripts/crouton/xinitrc ~/.xinitrc
ln -s ~/scripts/Xmodmap ~/.Xmodmap
```


## mysql-workbench hotkey fix

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
* using ssh-find-agent.sh, add `source ~/scripts/crouton/ssh-find-agent.sh` and `set_ssh_agent_socket` to `~/.bashrc`
* etherpad config file: `/opt/etherpad/local/etherpad/etherpad-lite/settings.json`
* if ssh-agent is not running: eval `ssh-agent -s`
* ssh-agent setup that actually worked on mint https://yashagarwal.in/posts/2017/12/setting-up-ssh-agent-in-i3/
* add this to `.bashrc`
```
if [ -f ~/.ssh/agent.env ] ; then
    . ~/.ssh/agent.env > /dev/null
    if ! kill -0 $SSH_AGENT_PID > /dev/null 2>&1; then
        echo "Stale agent file found. Spawning a new agent. "
        eval `ssh-agent | tee ~/.ssh/agent.env`
        ssh-add
    fi
else
    echo "Starting ssh-agent"
    eval `ssh-agent | tee ~/.ssh/agent.env`
    ssh-add
fi
```
* mosh is failing because of locale problems: https://www.codeandbytes.com/solucion-locale-cannot-set-lc_all-to-default-locale-no-such-file-or-directory/
```
sudo locale-gen en_US.UTF-8
export LANGUAGE=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
locale-gen en_US.UTF-8
sudo dpkg-reconfigure locales
```


# /etc/network/interfaces new style
```
iface lo inet loopback
auto lo

auto ens160
iface ens160 inet static
address 172.168.1.47
netmask 255.255.255.0
up route add default gw 172.168.1.1
dns-nameservers 8.8.8.8 8.8.4.4

up ip addr add 172.168.2.47/24 dev ens160
up ip addr add 172.168.3.47/24 dev ens160
```

# license

Copyright 2013 - 2023  David Ulrich (http://github.com/dulrich)

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
