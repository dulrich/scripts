

DIR="$( dirname -- "${BASH_SOURCE[0]}"; )";   # Get the directory name
DIR="$( realpath -e -- "$DIR"; )";    # Resolve its full path if need be

echo "$DIR"

PRG="$0"

# need this for relative symlinks
while [ -h "$PRG" ] ; do
   PRG=`readlink "$PRG"`
done

echo "$PRG"


# `"${BASH_SOURCE[0]}"` instead in order to get the first element from the array.
FULL_PATH_TO_SCRIPT="$(realpath "${BASH_SOURCE[-1]}")"
# B.1. `"$0"` works only if the file is **run**, but NOT if it is **sourced**.
# FULL_PATH_TO_SCRIPT_KEEP_SYMLINKS="$(realpath -s "$0")"
# B.2. `"${BASH_SOURCE[-1]}"` works whether the file is sourced OR run, and even
# if the script is called from within another bash function!
# NB: if `"${BASH_SOURCE[-1]}"` doesn't give you quite what you want, use
# `"${BASH_SOURCE[0]}"` instead in order to get the first element from the array.
FULL_PATH_TO_SCRIPT_KEEP_SYMLINKS="$(realpath -s "${BASH_SOURCE[-1]}")"

# You can then also get the full path to the directory, and the base
# filename, like this:
SCRIPT_DIRECTORY="$(dirname "$FULL_PATH_TO_SCRIPT")"
SCRIPT_FILENAME="$(basename "$FULL_PATH_TO_SCRIPT")"

# Now print it all out
echo "FULL_PATH_TO_SCRIPT = \"$FULL_PATH_TO_SCRIPT\""
echo "SCRIPT_DIRECTORY    = \"$SCRIPT_DIRECTORY\""
echo "SCRIPT_FILENAME     = \"$SCRIPT_FILENAME\""

here=$( dirname $( realpath "${BASH_SOURCE[-1]}" ) )

echo "here is <$here>"


there=$( dirname $( realpath "${BASH_SOURCE[0]}" ) )

echo "there is <$there>"


