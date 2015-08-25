// Magic 8 Ball: A silly script to "answer" questions
// Copyright 2015  David Ulrich
// 
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// 
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

process.stdin.resume();
process.stdin.setEncoding('utf8');

var answers = require("./answers");

var exit_codes = require("./exit_codes");

function do_magic(q) {
	var sum = 0;
	
	// who, what, where, why, when, how, how many|much
	var answer_type = "probability";
	if (q.indexOf("what") == 0 || q.indexOf("wat") == 0) {
		answer_type = "value";
	}
	else if (q.indexOf("when") == 0) {
		answer_type = "temporal";
	}
	else if (q.indexOf("why") == 0) {
		answer_type = "reason";
	}

	for(var i=0;i<q.length;i++) {
		sum += q.charCodeAt(i);
	}
	
	var answer_list = answers[answer_type];
	return answer_list[sum % answer_list.length];
}

var prompt = "What would you like to know? ";

process.stdout.write(prompt);
process.stdin.on("data", function (question) {
	question = question.toLowerCase().replace(/\n/g,"");
	
	if (exit_codes[question]) {
		process.exit();
	}
	
	console.log(do_magic(question));
	process.stdout.write(prompt);
});

