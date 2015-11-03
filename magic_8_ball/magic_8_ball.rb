# Magic 8 Ball: A silly script to "answer" questions
# Copyright 2015  David Ulrich
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

require 'json'

$answers = JSON.parse(IO.read("answers.json"))

exit_codes = JSON.parse(IO.read("exit_codes.json"))

def do_magic(q)
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
	answer_list = $answers[answer_type]
	return answer_list[sum % answer_list.length]
end

while true
	print "What would you like to know? "
	question = gets.chomp.downcase
	
	if exit_codes[question]
		break
	else
		puts do_magic(question)
	end
end
