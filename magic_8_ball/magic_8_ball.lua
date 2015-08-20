-- Magic 8 Ball: A silly script to "answer" questions
-- Copyright 2015  David Ulrich
-- 
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

json = require "JSON"

local answer_file = io.open("answers.json")
answers = json:decode(answer_file:read("*all"))
answer_file:close()

exit_responses = {
	exit =  true,
	no = true,
	nothing = true,
	quit = true
}
exit_responses["end"] = true -- lua keyword, prohibited in literal notation

function do_magic(q)
	local sum = 0
	
	-- who, what, where, why, when, how, how many|much
	local answer_type = "probability"
	if string.find(q,"what") == 0 or string.find(q,"wat") == 0 then
		answer_type = "value"
	elseif string.find(q,"when") == 0 then
		answer_type = "temporal"
	elseif string.find(q,"why") == 0 then
		answer_type = "reason"
	end
	
	for i = 1, #q do
		sum = sum + string.byte(q,i)
	end
	
	answer_list = answers[answer_type]
	return answer_list[sum % #answer_list]
end

while true do
	io.write("What would you like to know? ")
	question = io.read()
	question = string.lower(question)
	
	if exit_responses[question] then
		break
	else
		print(do_magic(question))
	end
end

