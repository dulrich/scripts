# daylog.sh: track what happens at a certain time, and view previous logs
# Copyright 2013 - 2015 David Ulrich
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

exit_responses = {
	'end' => true,
	'exit' => true,
	'no' => true,
	'nothing' => true,
	'quit' => true
}

def do_magic(q)
	answers_general = [
		"no",
		"yep",
		"nope",
		"maybe",
		"cloudy",
		"unclear",
		"certainly",
		"indubitably",
		"so it will be",
		"definitely not",
		"the mists of time are shrouded"
	]
	
	answers_value = [
		42,
		"your mom",
		"your data",
		"a very large sheep",
		"10 lords a-leaping",
		"Voldemort",
		"Cthulu"
	]
	
	letters = q.split("")
	sum = 0
	
	if q.slice(0,4) == "what" || q.slice(0,3) == "wat"
		answer_type = "value"
	end
	
	letters.each {|l| sum += l.ord}
	
	answer_type ||= "general"
	if answer_type == "value"
		return answers_value[sum % answers_value.length]
	else
		return answers_general[sum % answers_general.length]
	end
end

while true
	print "What would you like to know? "
	question = gets.chomp
	
	if exit_responses[question]
		break
	else
		puts do_magic(question)
	end
end
