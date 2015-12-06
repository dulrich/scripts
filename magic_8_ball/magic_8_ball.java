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

import org.json.JSONObject;

public class magic_8_ball {
	private static String do_magic(String q) {
		byte[] bytes;
		int sum = 0;
		
		// who, what, where, why, when, how, how many|much
		String answer_type = "probability";
		if (q.indexOf("what") == 0 || q.indexOf("wat") == 0) {
			answer_type = "value";
		}
		else if (q.indexOf("when") == 0) {
			answer_type = "temporal";
		}
		else if (q.indexOf("why") == 0) {
			answer_type = "reason";
		}
		
		bytes = q.getBytes();
		for(int i=0;i < bytes.length;i++) {
			sum += bytes[i];
		}
		
		return answer_type;
	}
	
	public static void main(String[] args) {
		System.out.println(do_magic("why are we here?"));
	}
}
