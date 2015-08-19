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

import json

with open("answers.json") as answers_data:
	answers = json.load(answers_data)

exit_responses = {
        'end':  True,
        'exit':  True,
        'no': True,
        'nothing': True,
        'quit': True
}

def do_magic(q):
	sum = 0
	
	# who, what, where, why, when, how, how many|much
        answer_type = "probability"
        if q.find("what") == 0 or q.find("wat") == 0:
		answer_type = "value"
        elif q.find("when") == 0:
		answer_type = "temporal"
        elif q.find("why") == 0:
		answer_type = "reason"
	
        for l in q:
            sum += ord(l)
	
	answer_list = answers[answer_type]
	return answer_list[sum % len(answer_list)]

while True:
	question = raw_input("What would you like to know? ")
	question = question.lower()
	
        if question in exit_responses:
		break
        else:
		print do_magic(question)

