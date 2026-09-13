CC      ?= gcc
CFLAGS  ?= -O2 -Wall

all: mnt

mnt: mnt.c
	$(CC) -static $(CFLAGS) -o $@ $<

clean:
	rm -f mnt

.PHONY: all clean