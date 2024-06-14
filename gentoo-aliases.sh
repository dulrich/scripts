#!/bin/bash

# gentoo-aliases.sh: shorten common gentoo tasks
# 2021 - 2024  David Ulrich
#
# CC0: This work has been marked as dedicated to the public domain. 
#
# You may have received a copy of the Creative Commons Public Domain dedication
# along with this program.  If not, see <https://creativecommons.org/publicdomain/zero/1.0/>.

alias upd="sudo emerge --sync"
alias upg="sudo emerge --ask --update --changed-use --deep --with-bdeps=y @world"
# emerge -auDN --keep-going @world

alias em="time sudo emerge --ask --tree"

alias mod_rebuild="sudo emerge @module-rebuild"

# eclean distfiles
# eclean packages




# todo: switch to git portage
# https://wiki.gentoo.org/wiki/Portage_with_Git


# sudo su -
# eselect kernel list
# eselect kernel set <n>
# cd /usr/src/linux
# make clean
# make oldconfig
# make -j9 && make modules_install
# make install
# mount /boot/efi
# grub-install
# grub-mkconfig -o /boot/grub/grub.cfg
# make modules_prepare
# emerge @module-rebuild

# cp /usr/src/linux/.config ./gentoo/X.Y.Z.config
# cp /var/lib/portage/world ./gentoo/world



# update/upgrade process
# upd
# upg
# remove --deep if conflicts
# rebuild kernel
# copy backup kernel config
# loop these until nothing
# eclean distfiles
# eclean packages
# emerge --depclean
# emerge --ask @preserved-rebuild
# eclean-kernel -n 2
# mandb



