
### https://gableroux.com/posts/2016-01-20-python-interpreter-autocomplete/
import atexit
import os
import sys

try:
	import readline
except ImportError:
	print(".pythonrc :: Module readline not available.")
else:
	import rlcompleter

	readline.parse_and_bind("tab: complete")
	print(".pythonrc :: AutoCompletion Loaded")

	# history_file = os.path.join(os.path.expanduser("~"), ".pyhistory")
	history_file = os.path.abspath(os.path.join(os.getcwd(), "./.pyhistory"))
	print(".pythonrc :: history file:", history_file)

	def save_history(history=history_file):
		import readline
		readline.write_history_file(history)
		print(".pythonrc :: history saved to " + history)

	def load_history(history=history_file):
		try:
			readline.read_history_file(history)
		except IOError:
			pass

	load_history()
	atexit.register(save_history)

	del readline, rlcompleter, atexit, history_file
###


# system imports
import glob
import json
from pprint import pprint as pp
import shutil

# library imports
import numpy as np
import scipy.stats as sps

# project imports
from Config import Config
from stats import *
from util import jp


####

config = Config()
#config.load_json(".mesh_export.json")

try:
	from data_file import *
except ImportError:
	print("Missing or invalid data file. Continuing without preset data.")




