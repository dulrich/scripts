#!/bin/bash
set -euo pipefail

# Usage: vault-snapshot <folder>
# Output: <folder>.YYYY-MM-DD.zip in the current working directory

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <folder>" >&2
    exit 1
fi

SOURCE_DIR="$1"
TIMESTAMP=$(date +"%Y-%m-%d")
BASENAME=$(basename "$SOURCE_DIR")
OUTPUT_FILE="${BASENAME}.${TIMESTAMP}.zip"

# Validate source directory
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: Directory '$SOURCE_DIR' not found." >&2
    exit 1
fi

echo "Creating snapshot of: $SOURCE_DIR"
echo "Output file: $OUTPUT_FILE"

# Create the zip archive
# -r: recursive
# -q: quiet (suppress progress bar for cleaner logs)
# -9: maximum compression
zip -rq9 "$OUTPUT_FILE" "$SOURCE_DIR"

if [[ $? -eq 0 ]]; then
    echo "Success: Archive created at $(pwd)/$OUTPUT_FILE"
else
    echo "Error: Failed to create archive." >&2
    exit 1
fi
