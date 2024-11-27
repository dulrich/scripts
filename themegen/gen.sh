#!/bin/bash

# load pastel|saturated
# load internal|external -> font config, transparency config

# generate HEX24 and HEX32 output format strings
source ./dark_pastel.sh

# dark_*.json
# light_*.json
# write $HOME/.Xresources
# xrdb -merge $HOME/.Xresources
# remove scripts/Xresources

SED_TOKENS=( \
FOREGROUND BACKGROUND CURSOR \
TRANSPARENCY TRANSPARENCY_XSTR \
FONTSIZE_SMALL FONTSIZE_MAIN
PURE_BLACK PURE_WHITE \
BLACK_LITE BLACK_DARK \
RED_LITE RED_DARK \
GREEN_LITE GREEN_DARK \
YELLOW_LITE YELLOW_DARK \
BLUE_LITE BLUE_DARK \
MAGENTA_LITE MAGENTA_DARK \
CYAN_LITE CYAN_DARK \
WHITE_LITE WHITE_DARK \
)

SED_TOKENS_MAX=$(( ${#SED_TOKENS[@]} - 1 ))

# do 32-bit rgba first
sed_files=( dark_pastel.json dark_saturated.json options.json )
for token in "${SED_TOKENS[@]}"; do
	echo "GEN_$token->${!token}"
	#sed -i -E -e "s;GEN_$token;${!token};" "${sed_files[@]}"
done


# chop last byte and do rgb only files
sed_files=( Xresources )
for token in "${SED_TOKENS[@]}"; do
	token_short=${token::-2}
	echo "GEN_$token->${!token_short}"
	#sed -i -E -e "s;GEN_$token;${!token_short};" "${sed_files[@]}"
done


