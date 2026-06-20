ZIG ?= zig
OPTIMIZE ?= ReleaseSafe
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
BINARY ?= scoot

.PHONY: all build test install uninstall clean

all: build

build:
	$(ZIG) build -Doptimize=$(OPTIMIZE)

test:
	$(ZIG) build test

install: build
	mkdir -p "$(BINDIR)"
	install -m 0755 "zig-out/bin/$(BINARY)" "$(BINDIR)/$(BINARY)"
	@case ":$$PATH:" in *:"$(BINDIR)":*) ;; *) printf '%s\n' 'warning: $(BINDIR) is not in PATH' >&2 ;; esac
	@printf 'installed %s\n' "$(BINDIR)/$(BINARY)"

uninstall:
	rm -f "$(BINDIR)/$(BINARY)"

clean:
	rm -rf .zig-cache zig-out
