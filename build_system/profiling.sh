#!/bin/bash

gcc _build.c -lutil -o ._build -ggdb \
	&& ./._build -pd \
	&& gdb -x ~/.gdbinit -ex=r --args ./hworld $@ \
	&& gprof ./hworld gmon.out > prof.out \
	&& nano prof.out
	
