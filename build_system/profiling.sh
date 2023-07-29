#!/bin/bash

gcc _build.c -lutil -o ._build -ggdb \
	&& ./._build -pd \
	&& gdb -x ~/.gdbinit -ex=r --args __SED_TOKEN_EXE_PATH__SED_TOKEN_EXE_NAME  $@ \
	&& gprof __SED_TOKEN_EXE_PATH__SED_TOKEN_EXE_NAME gmon.out > prof.out \
	&& nano prof.out
	
