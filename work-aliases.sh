#!/bin/bash

# work-aliases.sh: shorten common work tasks
# Copyright 2013 - 2021 David Ulrich
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

# dirs, eval style
cdnames=( cda                           cdb              cde                                   cdm                             cdg                cdc )
cdpaths=( $code_path/baced/tools/assman $code_path/baced $code_path/baced/tools/blender_export $code_path/baced/tools/meshtool $code_path/gpuedit $code_path/music_controller )

cdmax=$(( ${#cdnames[@]} - 1 ))

for (( i=0; i<=$cdmax; i++ ))
do
	aliascd ${cdnames[$i]} ${cdpaths[$i]}
done


plfig () {
	export BEACON_ROLE=$1
	export BEACON_CONFIG=$ENV_PATH/beacon.config.dev.$1
	export INTEL_LAYER_ID_BETA="qkhtuPADEeeZ+AENXM6thw"
    export INTEL_LAYER_ID_QA="4o2HoKudh0WaFPw5vTJPyw"
}
_plfig () {
	COMPREPLY=( $(compgen -W "dev local prod staging" "$2" ) )
	return 0
}
pltest () {
	source $ENV_PATH/beacon.testing.$1
}
_pltest () {
	COMPREPLY=( $(compgen -W "dev local prod staging" "$2" ) )
	return 0
}
_comp plfig
_comp pltest



# betty="192.168.50.13"
alias betty="ssh root@192.168.50.13"

# generate compare links, like:
# https://github.com/Stabilitas/beacon-alert-rules/compare/master...dulrich:master
# gl <from> <to>


# access psql on staging dbs (inside vpc)
# kubectl config use-context <your-staging-context>
# kubectl run psql -it --rm --restart=Never --image=jbergknoff/postgresql-client postgres://<username>:<password>@host/keystore

# available contexts:
# production.k8s.xembly.com
# eks-xembly-development

kube_cmd="kubectl --namespace=staging"
# alias kkp="$kube_cmd proxy"
kkt () {
	keyword=$1
	command="cat <("
	for line in $($kube_cmd get pods | \
	   grep $keyword | grep Running | awk '{print $1}'); do
       command="$command ($kube_cmd logs --tail=50 -f $line &) && "
	done
	command="$command echo)"
	eval $command
}
kke () {
	keyword=$1
	command="cat <("
	for line in $($kube_cmd get pods | \
	   grep "$keyword-[0-9]" | grep Running | awk '{print $1}'); do
       command="$command ($kube_cmd logs --tail=2 -f $line &) && "
	done
	command="$command echo)"
	eval $command
}

kku () {
	# kubectl config use-context ulrich-$1.stabilitas.io
	context=""
	if [ "$1" == "production" ]; then
		context="production.k8s.xembly.com"
	elif [ "$1" == "develop" ]; then
		context="dev.k8s.xembly.com"
	else
		echo "unknown context '$1'"
		return 1
	fi
	kubectl config use-context "$context"
}
_kku () {
	COMPREPLY=( $(compgen -W "develop production" "$2" ) )
	return 0
}
_comp kku


keybase_dir="/run/user/1000/keybase/kbfs/private/lariduskonivaich"
up_keybase () {
	if [ ! -d "$keybase_dir" ]; then
		run_keybase -g
	fi
}

kbdir () {
	up_keybase
	cd $keybase_dir
}

vpn () {
	conf_path="/tmp/.xembly.ovpn"
	up_keybase
	cp $keybase_dir/xembly/xembly-vpn-03.ovpn "$conf_path"
	sudo openvpn --config "$conf_path"
	# sudo /sbin/route add -net 10.0.0.0 $IP_GATEWAY_ASSIGNED 255.0.0.0 # pavel full tunnel fix
	rm "$conf_path"
}


pyfig () {
    up_keybase
	# option to source instead of copying file?
	env_type="$1"
	path_parts=( $(echo "$PWD" | sed "s/\// /g") )
	proj_name="${path_parts[-1]}"
	cp "$keybase_dir/$proj_name/env.$env_type" .env
}
_pyfig () {
	COMPREPLY=( $(compgen -W "debug develop fake_prod fake_staging prod staging test" "$2" ) )
	return 0
}
_comp pyfig


startup() {
	ssh-add
	sudo systemctl start kafka
	vpn
}


team() {
	TZ='Europe/Prague'       date +"Prague  %_I:%M%p"
	TZ='Europe/Samara'       date +"Samara  %_I:%M%p"
	TZ='America/Los_Angeles' date +"Seattle %_I:%M%p"
	TZ='America/Mexico_City' date +"ZMG     %_I:%M%p"
}


# new section for hoa
hoa () {
	cd /web/hoa-$1
}

_hoa () {
	COMPREPLY=( $(compgen -W "client lib sympathy-server" "$2" ) )
	return 0
}
_comp hoa


hoaf () {
	fname="$1"

	# header
	touch "$fname.h"
	echo -e "// hoa sympathy server" >> "$fname.h"
	echo -e "// Copyright (C) 2020 - 2021  David Ulrich\n" >> "$fname.h"
	echo -e "#ifndef HOA_${fname^^}_H" >> "$fname.h"
	echo -e "#define HOA_${fname^^}_H\n" >> "$fname.h"
	echo -e "#include \"defines.h\"\n\n\n" >> "$fname.h"
	echo -e "#endif // HOA_${fname^^}_H" >> "$fname.h"

	# source
	touch "$fname.c"
	echo -e "// hoa sympathy server" >> "$fname.c"
	echo -e "// Copyright (C) 2020 - 2021  David Ulrich\n" >> "$fname.c"
	echo -e "#include \"$fname.h\"\n" >> "$fname.c"
	echo -e "#define FDEBUG FDEBUG_G" >> "$fname.c"
	echo -e "// #define FDEBUG(...)\n\n\n" >> "$fname.c"
	echo -e "#undef FDEBUG" >> "$fname.c"
	
}


git_dirs=( baced c3dlas c_json diez_equis gpuedit sti )

dirsmax=$(( ${#git_dirs[@]} - 1 ))

uall () {
	for (( i=0; i<=$dirsmax; i++ ))
	do
		echo "Checking ${git_dirs[$i]}..."
		cd "$code_path/${git_dirs[$i]}"
		git pull
	done
	cd "$code_path/${git_dirs[0]}"
}

uassets() {
	cd "$code_path/${git_dirs[0]}/assets"
	rsync -rv root@192.168.50.13:/mnt/hoard/baced_assets/* .
	cd "$code_path/${git_dirs[0]}"
}

hoard() {
	path=/mnt/hoard
	mountpoint -q $path
	if [ $? -ne 0 ]; then
		sshfs -o reconnect fractal@betty:/mnt/hoard $path
	fi
}
unhoard() {
	umount /mnt/hoard
}

assets() {
	path=/mnt/baced_assets_raw
	mountpoint -q $path
	if [ $? -ne 0 ]; then
		sshfs -o allow_other,reconnect baced_assets@betty:/mnt/hoard/baced_assets_raw $path
	fi
}
unassets() {
	umount /mnt/baced_assets_raw
}


# running git webviewer
#
# ssh root@192.168.50.13
# screen -S gitwebstack
# su -s /bin/bash git
# cd /home/git
# ./git_webstack ./gitviewer_root/


# new empty repos can be created in the system by:
#
# ssh root@192.168.50.13
# su -s /bin/bash git
# cd /home/git
# git_webviewer ./gitviewer_root --add-repo fractal <reponame>


# new empty repo on ulrichdev
# 
# sudo su - git
# cd /opt/git/
# git init --bare <reponame>.git








