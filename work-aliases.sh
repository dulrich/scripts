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
cdnames=( ca                   cb                   cbb                                  cby                     cdf                               cs                    ci                                  car                          cr                              cv                      cdp                       cdl                          cda                       cva )
cdpaths=( $web_path/beacon-api $web_path/beacon-lib $web_path/beacon-basic-communication $web_path/beacon-lib-py $web_path/beacon-realtime-filters $web_path/beacon-site $web_path/beacon-internal-dashboard $web_path/beacon-alert-rules $web_path/beacon-pace-processor $web_path/beacon-devops $web_path/beacon-pipeline $web_path/beacon-data-loader $web_path/beacon-data-api $web_path/beacon-travel-api )

for i in {0..13}
do
	aliascd ${cdnames[$i]} ${cdpaths[$i]}
done

alias aa="a api1.pl Beacon/ sql/"
alias da="d api1.pl Beacon/ sql/"
fs () {
	git fetch stabilitas $(defarg "$*" 0 master)
}
ms () {
	git merge stabilitas $(defarg "$*" 0 master)
}
pps () {
	local branch=$(git rev-parse --abbrev-ref HEAD)

	git push origin $(defarg "$*" 0 $branch)
	git push stabilitas $(defarg "$*" 0 $branch)
}
us () {
	u stabilitas $(defarg "$*" 0 master)
}

beacon_role="BEACON_ROLE=dev"
api="perl api1.pl daemon"
alias api="$api"
alias apikill="pkill -SIGKILL -f '$api'"
alias pgkill="killall pgadmin3"
alias pipeline="cd /web/beacon-pipeline/ && source beacon_pipeline_3_7/bin/activate && pyfig local && cd app"
alias site="sudo API_SERVER_URL=http://localhost:3000 yarn start"

prfig () {
	export BEACON_ROLE=$1
	export BEACON_CONFIG=$ENV_PATH/beacon.config.dev.$1
}
_prfig () {
	COMPREPLY=( $(compgen -W "dev local prod staging" "$2" ) )
	return 0
}
_comp prfig

pyfig () {
	source $ENV_PATH/python.config.$1
}
_pyfig () {
	COMPREPLY=( $(compgen -W "local prod staging" "$2" ) )
	return 0
}
_comp pyfig

apitest () {
	local t="$1"

	if [ ${t: -2} != ".t" ]; then
		t="$t.t"
	fi

	BEACON_ROLE=dev perl api1.pl test t/$t
}

alerts="perl triggers.pl daemon"
alias alerts="$beacon_role $alerts"
alias alertskill="pkill -SIGKILL -f '$alerts'"

alertstest () {
	local t="$1"

	if [ ${t: -2} != ".t" ]; then
		t="$t.t"
	fi

	BEACON_ROLE=local perl t/$t
}

comms="perl basic_communication.pl daemon"
alias comms="$beacon_role $comms"
alias commskill="pkill -SIGKILL -f '$comms'"

pace="perl pace_processor.pl"
alias pace="$beacon_role $pace --role"
alias pacekill="pkill -SIGKILL -f '$pace'"

alias vpn="cd ~/vpn ; sudo openvpn --config client.ovpn --script-security 2"
alias vpn_staging="cd ~/vpn ; sudo openvpn --config staging-client.ovpn --script-security 2"

alias ssa="ssh -i $web_path/keys/general-dev.pem ubuntu@54.173.18.178"
alias ssp="ssh -i $web_path/keys/general-dev.pem ubuntu@172.31.154.23"

alias ssc="ssh -i $web_path/keys/general-dev.pem ubuntu@pace.stabilitas.internal"
alias ssn="ssh -i $web_path/keys/general-dev.pem ubuntu@172.31.70.189"
alias ssr="ssh -i $web_path/keys/general-dev.pem ubuntu@172.31.72.102"
alias sss="ssh -i $web_path/keys/general-dev.pem ubuntu@172.31.35.37"
alias sst="ssh -i $web_path/keys/general-dev.pem ubuntu@notifications.stabilitas.internal"


# generate compare links, like:
# https://github.com/Stabilitas/beacon-alert-rules/compare/master...dulrich:master
# gl <from> <to>

synclib () {
	local beacon_files=( Configuration Magic Modern Notification NotificationResponse PacePlan PushService ShortGuid Twilio )
	for i in {0..8}
	do
		cp Beacon/${beacon_files[$i]}.pm ../beacon-lib/Beacon/.
	done
}


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
