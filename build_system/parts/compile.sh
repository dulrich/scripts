#!/bin/bash
set -euo pipefail

rm -f ../_build.inc.c

cat strlist.c header.c \
	string.c \
	strcache.c \
	hash.c \
	fs.c \
	pkgconfig.c \
	init.c \
	cprocs.c \
	rglob.c \
	gcc.c \
	\
	>> ../_build.inc.c







