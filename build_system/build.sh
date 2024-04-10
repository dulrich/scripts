#!/bin/bash

source ./build-flags.sh

gcc $gcc_flags _build.c -lutil -o ._build -ggdb \
	&& ./._build $@ 
