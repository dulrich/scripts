#!/bin/bash

# This sourced fragment supplies one argv element per compiler flag.
# shellcheck disable=SC2034
gcc_flags=(
	-Wall
	-Werror
	-Wno-unused-variable
	-Wno-unused-label
	-Wno-parentheses
	-Wno-comment
)

