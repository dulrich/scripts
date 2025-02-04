
import json


def jp_default(o):
	try:
		 iterable = iter(o)
	except TypeError:
		 pass
	else:
		 return list(iterable)
	try:
		return json.JSONEncoder.default(json.JSONEncoder, o)
	except TypeError:
		return repr(o)


def jp(obj):
	print(json.dumps(obj, indent=4, default=jp_default))



