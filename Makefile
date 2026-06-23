ZIG ?= zig
OPTIMIZE ?= ReleaseSafe
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
BINARY ?= scoot

.PHONY: all build test fmt fmt-check ci hooks install uninstall clean

all: build

build:
	$(ZIG) build -Doptimize=$(OPTIMIZE)

test:
	$(ZIG) build test

# Rewrite sources in place to satisfy the formatter (mirrors CI's checked paths).
fmt:
	$(ZIG) fmt build.zig src examples

# Non-mutating format check, as run in CI.
fmt-check:
	$(ZIG) fmt --check build.zig src examples

# Local CI: mirror the GitHub Actions `zig` job (fmt, build, test, release, smoke).
# Run this before opening a pull request. LOCAL_CI_CROSS=1 / LOCAL_CI_DOCS=1 add
# the cross-compile and docs jobs.
ci:
	./scripts/local-ci.sh

# Point git at the versioned hooks so `git push` runs local CI first.
hooks:
	git config core.hooksPath .githooks
	@printf 'git hooks enabled: core.hooksPath=.githooks (pre-push runs local CI)\n'

install: build
	mkdir -p "$(BINDIR)"
	install -m 0755 "zig-out/bin/$(BINARY)" "$(BINDIR)/$(BINARY)"
	@case ":$$PATH:" in *:"$(BINDIR)":*) ;; *) printf '%s\n' 'warning: $(BINDIR) is not in PATH' >&2 ;; esac
	@printf 'installed %s\n' "$(BINDIR)/$(BINARY)"

uninstall:
	rm -f "$(BINDIR)/$(BINARY)"

clean:
	rm -rf .zig-cache zig-out
