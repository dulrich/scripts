# link .bash_aliases to the repo aliases file
rm ~/.bash_aliases
ln -s ~/scripts/aliases.sh ~/.bash_aliases

# link irssi scripts into the repo
mkdir -p ~/.irssi
rm ~/.irssi/scripts
ln -s ~/scripts/irssi_scripts ~/.irssi/scripts