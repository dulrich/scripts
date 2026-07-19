#!/bin/bash
set -euo pipefail

# load pastel|saturated
# load internal|external -> font config, transparency config

# generate HEX24 and HEX32 output format strings
# The selected palette is a sibling sourced-data fragment; the repo gate runs
# without ShellCheck's external-source mode.
# shellcheck source=dark_pastel.sh
# shellcheck disable=SC1091
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/dark_pastel.sh"

# dark_*.json
# light_*.json
# write $HOME/.Xresources
# xrdb -merge $HOME/.Xresources
# remove scripts/Xresources

SED_TOKENS=( \
TRANSPARENCY_XSTR \
FONTSIZE_SMALL FONTSIZE_MAIN \
)

SED_COLOR_TOKENS=( \
FOREGROUND BACKGROUND CURSOR \
TRANSPARENCY \
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

# do 32-bit rgba for json files
# Retained for the disabled in-place generation command immediately below.
# shellcheck disable=SC2034
sed_rgba_files=( dark_pastel.json dark_saturated.json options.json )
for token in "${SED_TOKENS[@]}" "${SED_COLOR_TOKENS[@]}"; do
	echo "GEN_$token->${!token}"
	#sed -i -E -e "s;GEN_$token;${!token};" "${sed_rgba_files[@]}"
done


# chop alpha byte for Xresources: settings as-is, colors stripped to rgb
# Retained for the disabled in-place generation commands immediately below.
# shellcheck disable=SC2034
sed_rgb_files=( Xresources )
for token in "${SED_TOKENS[@]}"; do
	echo "GEN_$token->${!token}"
	#sed -i -E -e "s;GEN_$token;${!token};" "${sed_rgb_files[@]}"
done
for token in "${SED_COLOR_TOKENS[@]}"; do
	value="${!token}"
	echo "GEN_$token->${value::-2}"
	#sed -i -E -e "s;GEN_$token;${value::-2};" "${sed_rgb_files[@]}"
done
