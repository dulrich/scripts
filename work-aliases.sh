#!/bin/bash

# work-aliases.sh: shorten common work tasks
# Copyright 2013 - 2017 David Ulrich
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
cdnames=( cdb                       cdp                        )
cdpaths=( $code_path/xembly-backend $code_path/xembly-pipeline )

for i in {0..1}
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

pyfig () {
	source $ENV_PATH/python.config.$1
}
_pyfig () {
	COMPREPLY=( $(compgen -W "local prod staging" "$2" ) )
	return 0
}
_comp pyfig


# generate compare links, like:
# https://github.com/Stabilitas/beacon-alert-rules/compare/master...dulrich:master
# gl <from> <to>


# access psql on staging dbs (inside vpc)
# kubectl config use-context <your-staging-context>
# kubectl run psql -it --rm --restart=Never --image=jbergknoff/postgresql-client postgres://<username>:<password>@host/keystore

alias kkp="kubectl proxy"
kkt () {
	keyword=$1
	command="cat <("
	for line in $(kubectl get pods | \
	   grep $keyword | grep Running | awk '{print $1}'); do
       command="$command (kubectl logs --tail=2 -f $line &) && "
	done
	command="$command echo)"
	eval $command
}
kke () {
	keyword=$1
	command="cat <("
	for line in $(kubectl get pods | \
	   grep "$keyword-[0-9]" | grep Running | awk '{print $1}'); do
       command="$command (kubectl logs --tail=2 -f $line &) && "
	done
	command="$command echo)"
	eval $command
}

kku () {
	kubectl config use-context ulrich-$1.stabilitas.io
}
_kku () {
	COMPREPLY=( $(compgen -W "production staging" "$2" ) )
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
	cp $keybase_dir/xembly/xembly.ovpn "$conf_path"
	sudo openvpn --config "$conf_path"
	rm "$conf_path"
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
