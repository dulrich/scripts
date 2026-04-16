#!/bin/bash
set -euo pipefail


dashes="----------"
py_version="3.12"


if ! command -v "python${py_version}" > /dev/null 2>&1; then
	echo "Missing required python version $py_version"
	exit 1
fi
py_path=$(command -v "python${py_version}")
echo "Found python $py_version at $py_path"
echo "$dashes"


if ! command -v virtualenv > /dev/null 2>&1; then
	echo "Missing virtualenv package. Please emerge"
	echo "$dashes"
	emerge -av dev-python/virtualenv
fi



venv_dir="venv"
if [ ! -d ./$venv_dir ]; then
	echo "didn't find venv in the current directory, making it now"
	echo "$dashes"
	virtualenv --python=python$py_version $venv_dir
fi



source $venv_dir/bin/activate

pip install --upgrade pip
pip install -r requirements.txt



echo "done."
echo "$dashes"



echo "now check config then run ./stats"

