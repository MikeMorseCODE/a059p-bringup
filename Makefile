# Nothing Phone (3a) Pro (A059P) Linux bring-up toolkit
#
#   make check          syntax-check every script
#   make test           run the regression suite against tests/expected
#   make update-goldens rewrite the goldens after an intended change
#   make install        PREFIX=/usr/local by default, honours DESTDIR
#   make dist           build dist/asteroids-port-<version>.tar.gz
#   make clean

VERSION := $(shell cat VERSION)
PREFIX ?= /usr/local
DESTDIR ?=
PYTHON ?= python3
PKGNAME := asteroids-port-tools

SHARE := $(DESTDIR)$(PREFIX)/share/asteroids-port
BINDIR := $(DESTDIR)$(PREFIX)/bin

SCRIPTS := $(wildcard scripts/*.sh)
TOOLS := check-payload assemble-unixnu-payload build-initramfs inject-boot-dump \
	diagnose-boot ufs-layout rootfs-plan

.PHONY: all check test update-goldens install dist apk clean

all: check

check:
	@for f in $(SCRIPTS) tests/regress.sh; do \
		sh -n "$$f" || { echo "syntax error: $$f"; exit 1; }; \
	done
	@$(PYTHON) -c "compile(open('scripts/cpio-tool.py').read(), 'cpio-tool.py', 'exec')"
	@echo "check: all scripts parse"

test: check
	@sh tests/regress.sh

update-goldens:
	@sh tests/regress.sh --update

install:
	@mkdir -p "$(SHARE)" "$(BINDIR)"
	@cp -R scripts initramfs tests "$(SHARE)/"
	@cp README.md VERSION BRINGUP-TEST-PROCEDURE.md DEVICE-PACKAGE-CHECKLIST.md \
		"$(SHARE)/"
	@cp a059p-fixes.patch "0001-arm64-dts-qcom-milos-enable-ufs.patch" "$(SHARE)/"
	@cp -R pmaports "$(SHARE)/"
	@for t in $(TOOLS); do \
		printf '%s\n' \
			'#!/bin/sh' \
			'# Generated wrapper: keeps the share/ tree intact so the tools find' \
			'# cpio-tool.py, inject-boot-dump.sh and the initramfs fragment.' \
			"exec sh \"\$$(dirname \"\$$0\")/../share/asteroids-port/scripts/$$t.sh\" \"\$$@\"" \
			> "$(BINDIR)/asteroids-$$t"; \
		chmod 0755 "$(BINDIR)/asteroids-$$t"; \
	done
	@echo "installed $(words $(TOOLS)) tools in $(BINDIR)"
	@echo "share tree: $(SHARE)"

dist: check
	@mkdir -p dist
	@tar -czf "dist/asteroids-port-$(VERSION).tar.gz" \
		--exclude='dist' \
		--exclude='__pycache__' \
		-C .. asteroids-port
	@echo "built dist/asteroids-port-$(VERSION).tar.gz"
	@sha256sum "dist/asteroids-port-$(VERSION).tar.gz"

# Build an aport that pmbootstrap can build: source tarball + APKBUILD with
# checksums filled in from that exact tarball. Copy both files into
# pmaports/testing/asteroids-port-tools/ and run
#   pmbootstrap build asteroids-port-tools
apk: check
	@rm -rf dist/apk
	@mkdir -p dist/apk
	@stage=$$(mktemp -d); trap 'rm -rf "$$stage"' EXIT; \
		mkdir -p "$$stage/$(PKGNAME)-$(VERSION)"; \
		tar -cf - --exclude=dist --exclude=__pycache__ \
			--exclude=.git --exclude=.github . | \
			tar -xf - -C "$$stage/$(PKGNAME)-$(VERSION)"; \
		tar -czf "dist/apk/$(PKGNAME)-$(VERSION).tar.gz" \
			-C "$$stage" "$(PKGNAME)-$(VERSION)"
	@sum=$$(sha512sum "dist/apk/$(PKGNAME)-$(VERSION).tar.gz" | cut -d' ' -f1); \
		sed -e "s/@PKGVER@/$(VERSION)/" -e "s/@SHA512@/$$sum/" \
			-e "s/@TARBALL@/$(PKGNAME)-$(VERSION).tar.gz/" \
			packaging/APKBUILD.in > "dist/apk/APKBUILD"; \
		echo "aport ready in dist/apk/:"; \
		ls -l dist/apk/APKBUILD "dist/apk/$(PKGNAME)-$(VERSION).tar.gz"; \
		echo "sha512: $$sum"

clean:
	@rm -rf dist
	@find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "clean"
