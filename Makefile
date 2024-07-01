.PHONY = all install

all: xdg2lynxcfg.pl xdg2lynxcfg.1.gz

xdg2lynxcfg.1.gz: xdg2lynxcfg.pl
	pod2man $^ | gzip -9c > $@

PREFIX ?= /opt
MANDIR ?= $(PREFIX)/share/man
BINDIR ?= $(PREFIX)/bin

install: all
	install -D -m 644 xdg2lynxcfg.1.gz $(MANDIR)/man1/
	install -D -t $(BINDIR) xdg2lynxcfg.pl
