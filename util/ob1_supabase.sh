#!/bin/bash


if [ "$#" -ne 2 ]; then
	echo "Usage: ob1_supabase <EXTENSION_NAME> <DOWNLOAD_PATH>"
	exit 1
fi


if [ -f .env ]; then
	source .env
else
	echo "could not locate .env in current dir for MCP_ACCESS_KEY and SUPABASE_URL"
	exit 2
fi

case "$TERM" in
#	rxvt-unicode*)
#		echo ""
#		;;
	xterm-kitty)
		#echo "kitty"
		# todo bien
		;;
	*)
		echo "unsupported terminal: $TERM (use kitty)"
		exit 3
		;;
esac


EXTENSION_NAME="$1"
DOWNLOAD_PATH="$2"
FUNCTION_NAME="$EXTENSION_NAME-mcp"


supabase functions new $FUNCTION_NAME

curl -o supabase/functions/$FUNCTION_NAME/index.ts \
	https://raw.githubusercontent.com/NateBJones-Projects/OB1/main/$DOWNLOAD_PATH/index.ts
curl -o supabase/functions/$FUNCTION_NAME/deno.json \
	https://raw.githubusercontent.com/NateBJones-Projects/OB1/main/$DOWNLOAD_PATH/deno.json

supabase functions deploy $FUNCTION_NAME --no-verify-jwt

echo "$MCP_ACCESS_KEY"

claude mcp add --transport http $EXTENSION_NAME $SUPABASE_URL/functions/v1/$FUNCTION_NAME --header "x-access-key: $MCP_ACCESS_KEY"


