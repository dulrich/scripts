using System;
using System.Collections.Generic;
using Newtonsoft.Json;

namespace Magic.Eight.Ball {
	public class AnswerLists {
		public List<string> ProbabilityList;
		public List<string> ReasonList;
		public List<string> TemporalList;
		public List<string> ValueList;
	}
	
	public class magic_8_ball {
		private static AnswerLists answers;
		private static List<string> exit_codes;
		
		private static string do_magic(string q) {
			byte[] bytes;
			int sum = 0;
			List<string> answer_list;
			
			answer_list = answers.ProbabilityList;
			if (q.IndexOf("what") == 0 || q.IndexOf("wat") == 0) {
				answer_list = answers.ValueList;
			}
			else if (q.IndexOf("when") == 0) {
				answer_list = answers.TemporalList;
			}
			else if (q.IndexOf("why") == 0) {
				answer_list = answers.ReasonList;
			}
			
			bytes = System.Text.Encoding.ASCII.GetBytes(q);
			for(int i=0;i < bytes.Length;i++) {
				sum += bytes[i];
			}
			
			return answer_list[sum % answer_list.Count];
		}
		
		private static void LoadAnswerLists(string path) {
			List<string> current_list = null;
			string current_token;
			string answer_list_data = System.IO.File.ReadAllText("answers.json");
			
			JsonTextReader reader = new JsonTextReader(new System.IO.StringReader(answer_list_data));
			while (reader.Read()) {
				if (reader.Value == null) continue;
				
				if (reader.TokenType == JsonToken.PropertyName) {
					current_token = reader.Value.ToString();
					
					if (current_token == "probability") current_list = answers.ProbabilityList;
					else if (current_token == "reason") current_list = answers.ReasonList;
					else if (current_token == "temporal") current_list = answers.TemporalList;
					else if (current_token == "value") current_list = answers.ValueList;
				}
				else if (reader.TokenType == JsonToken.String && current_list != null) {
					current_list.Add(reader.Value.ToString());
				}
			}
		}
		
		private static List<string> LoadExitCodes(string path) {
			List<string> exit_codes = new List<string>();
			
			string exit_codes_data = System.IO.File.ReadAllText("exit_codes.json");
			
			JsonTextReader reader = new JsonTextReader(new System.IO.StringReader(exit_codes_data));
			while (reader.Read()) {
				if (reader.TokenType == JsonToken.PropertyName && reader.Value != null) {
					exit_codes.Add(reader.Value.ToString());
				}
			}
			
			return exit_codes;
		}
		
		public static void Main(string[] args) {
			answers = new AnswerLists();
			answers.ProbabilityList = new List<string>();
			answers.ReasonList = new List<string>();
			answers.TemporalList = new List<string>();
			answers.ValueList = new List<string>();
			
			LoadAnswerLists("answers.json");
			
			exit_codes = LoadExitCodes("exit_codes.json");
			
			string question;
			while (true) {
				Console.WriteLine("What would you like to know?");
				question = Console.ReadLine().ToLower();
				
				if (exit_codes.IndexOf(question) > -1) {
					break;
				}
				else {
					Console.WriteLine(do_magic(question));
				}
			}
		}
	}
}
