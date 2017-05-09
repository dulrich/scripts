#!/bin/bash

# work-aliases.sh: shorten common work tasks
# Copyright 2013 - 2016 David Ulrich
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
cdnames=( ca                   cb                   cs                    car                          cr                              cv                      cbn                         ct                     can )
cdpaths=( $web_path/beacon-api $web_path/beacon-lib $web_path/beacon-site $web_path/beacon-alert-rules $web_path/beacon-pace-processor $web_path/beacon-devops $web_path/beacon-lib-dotnet $web_path/beacon-telco $web_path/beacon-api-dotnet )

for i in {0..8}
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

beacon_role="BEACON_ROLE=local"
api="perl api1.pl daemon"
alias api="$beacon_role $api"
alias apikill="pkill -SIGKILL -f '$api'"

apitest () {
	local t="$1"

	if [ ${t: -2} != ".t" ]; then
		t="$t.t"
	fi
	
	BEACON_ROLE=local perl api1.pl test t/$t
}

alerts="perl rules_processor.pl daemon"
alias alerts="$beacon_role $alerts"
alias alertskill="pkill -SIGKILL -f '$alerts'"

alertstest () {
	local t="$1"

	if [ ${t: -2} != ".t" ]; then
		t="$t.t"
	fi
	
	BEACON_ROLE=local perl t/$t
}

pace="perl pace_processor.pl"
alias pace="$beacon_role $pace --role"
alias pacekill="pkill -SIGKILL -f '$pace'"

alias vpn="sudo openvpn --config client.ovpn --script-security 2"

alias deployapi="perl deploy_package.pl -p sv-api-dev"
alias deployweb="perl package_site.pl -b dev"

alias sss="ssh -i $web_path/keys/general-dev.pem ubuntu@sync.stabilitas.io"
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
