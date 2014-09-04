# scripts

Simple utility scripts and helpful bash aliases

## aliases.sh

Defines A number of aliases and functions.

Recommended usage: add the line `source ~/scripts/aliases.sh` to `~/.bash_aliases` or `~/.bashrc` so that `aliases.sh` will be loaded along with whatever other local aliases you use.
Alternately: run `./links.sh`, which is the same as `ln -s ~/scripts/aliases.sh ~/.bash_aliases`

Chain-loads `git-aliases.sh` and `work-aliases.sh`

## daylog.sh

Program for tracking what was going on at a certain time, and viewing logs
from previous days.

## setting up a new machine

```bash
sudo apt-get install gmrun htop kate suckless-tools i3
```

## mysql-workbench Hotkey Fix

Edit `/usr/share/mysql-workbench/data/main_menu.xml` to update shortcut keys.

## Working with forked projects

`git clone git@github.com:/you/your-fork` or `git remote set-url origin git@github.com:/you/your-fork`

Track upstream: https://help.github.com/articles/syncing-a-fork then run (using aliases):
```bash
git remote add upstream git@github.com:/official/official-fork
f
u
m
```

