#!/bin/bash

# gentoo-aliases.sh: shorten common gentoo tasks
# Copyright 2021 - 2024  David Ulrich
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

alias upd="sudo emerge --sync"
alias upg="sudo emerge --ask --update --changed-use --deep --with-bdeps=y @world"
# emerge -auDN --keep-going @world

alias em="time sudo emerge --ask --tree"

alias mod_rebuild="sudo emerge @module-rebuild"

# eclean distfiles
# eclean packages




# done: switch to git portage
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
# cp /etc/portage/package.accept_keywords ./gentoo/package.accept_keywords



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



