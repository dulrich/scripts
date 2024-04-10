#!/bin/bash

source ./build-flags.sh

gcc $gcc_flags _build.c -lutil -o ._build -ggdb \
	&& ./._build -d \
	&& ./valgrind __SED_TOKEN_EXE_PATH__SED_TOKEN_EXE_NAME $@
