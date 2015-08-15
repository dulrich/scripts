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
	answers = {
		"probability" => [
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
		],
		
		"reason" => [
			"for fun",
			"for the children",
			"just because",
			"no reason"
		],
		
		"temporal" => [
			"immediately",
			"long, long ago",
			"once upon a time",
			"never",
			"right now",
			"yesterday"
		],
		
		"value" => [
			42,
			"your mom",
			"your data",
			"a very large sheep",
			"10 lords a-leaping",
			"Voldemort",
			"Cthulu"
		]
	}
	
	letters = q.split("")
	sum = 0
	
	# who, what, where, why, when, how, how many|much
	if q.slice(0,4) == "what" || q.slice(0,3) == "wat"
		answer_type = "value"
	elsif q.slice(0,4) == "when"
		answer_type = "temporal"
	elsif q.slice(0,3) == "why"
		answer_type = "reason"
	end
	
	letters.each {|l| sum += l.ord}
	
	answer_type ||= "probability"
	answer_list = answers[answer_type]
	return answer_list[sum % answer_list.length]
end

while true
	print "What would you like to know? "
	question = gets.chomp.downcase
	
	if exit_responses[question]
		break
	else
		puts do_magic(question)
	end
end
