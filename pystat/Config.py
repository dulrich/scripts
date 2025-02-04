
import json

class Config():
	export_base_dir = None
	models_dir = None
	log_level = "DEBUG"
	
	def __init__(self, data=None):
		self.patch(data)
	
	
	def load_json(self, path):
		data = None
		with open(path) as f:
			data = json.load(f)
		if data is None:
			return
		self.patch(data)
		
	
	def patch(self, data):
		if data is not None and type(data) is dict:
			fields = [
				"export_base_dir",
				"models_dir",
				"log_level",
			]
			for field in fields:
				if field in data:
					setattr(self, field, data[field])



