CC      ?= gcc
CFLAGS  ?= -O2 -Wall

all: revsh

revsh: revsh.c
	$(CC) -static $(CFLAGS) -o $@ $<

clean:
	rm -f revsh

.PHONY: all clean