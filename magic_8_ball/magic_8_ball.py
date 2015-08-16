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

exit_responses = {
        'end':  True,
        'exit':  True,
        'no': True,
        'nothing': True,
        'quit': True
}

def do_magic(q):
	answers = {
                "probability": [
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
		
                "reason": [
			"for fun",
			"for the children",
			"just because",
			"no reason"
		],
		
                "temporal": [
			"immediately",
			"long, long ago",
			"once upon a time",
			"never",
			"right now",
			"yesterday"
		],
		
                "value": [
			42,
			"your mom",
			"your data",
			"a very large sheep",
			"10 lords a-leaping",
			"Voldemort",
			"Cthulu"
		]
	}
	
	#letters = q.split("")
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

