# cuelight -- Caps Lock LED indicator for the coding agents you run.
#
#   make            build the app bundle
#   make test       run the checks over Core/
#   make install    build, install into /Applications and PATH, relaunch
#   make uninstall  remove everything but your config
#   make release    zip the bundle for a GitHub release
#   make clean      throw away build output

VERSION ?= 2.0.0-alpha
APP      = build/cuelight.app
BUNDLE   = com.odiumuniverse.cuelight

# The bundle promises macOS 13 (LSMinimumSystemVersion below), but swiftc defaults to
# the host's OS version: built on a newer runner, the app refuses to launch on anything
# older with "built for macOS N which is newer than running OS". Pin the floor here.
TARGET  ?= $(shell uname -m)-apple-macos13.0

# A self-signed code signing identity pins the designated requirement to the
# certificate instead of the cdhash, so the Input Monitoring grant survives rebuilds.
# Without it the build falls back to ad-hoc, which is what made the grant reset on
# every update. Override SIGN_IDENTITY to sign with a different identity.
SIGN_IDENTITY ?= odiumuniverse code signing

# Core/ is free of AppKit and IOKit, so the tests can compile against it directly.
# App/ is the shell around it. A new file in either is picked up without editing this.
CORE     = $(wildcard Sources/cuelight/Core/*.swift)
APPSRC   = $(wildcard Sources/cuelight/App/*.swift)
SOURCES  = $(CORE) $(APPSRC)

# Apple silicon Homebrew is already on PATH and fpath; Intel and plain installs are not.
PREFIX  ?= $(shell [ -d /opt/homebrew ] && echo /opt/homebrew || echo /usr/local)
COMPDIR  = $(PREFIX)/share/zsh/site-functions

.PHONY: all build test install uninstall release clean run help

all: build

## build the app bundle
build: $(APP)

$(APP): $(SOURCES) Resources/cuelight.icns Makefile
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	swiftc -O -target $(TARGET) $(SOURCES) -o $(APP)/Contents/MacOS/cuelight
	@cp Resources/cuelight.icns $(APP)/Contents/Resources/cuelight.icns
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0">' \
	  '<dict>' \
	  '    <key>CFBundleName</key><string>cuelight</string>' \
	  '    <key>CFBundleDisplayName</key><string>cuelight</string>' \
	  '    <key>CFBundleIdentifier</key><string>$(BUNDLE)</string>' \
	  '    <key>CFBundleExecutable</key><string>cuelight</string>' \
	  '    <key>CFBundleIconFile</key><string>cuelight</string>' \
	  '    <key>CFBundlePackageType</key><string>APPL</string>' \
	  '    <key>CFBundleShortVersionString</key><string>$(VERSION)</string>' \
	  '    <key>CFBundleVersion</key><string>$(VERSION)</string>' \
	  '    <key>LSMinimumSystemVersion</key><string>13.0</string>' \
	  '    <key>LSUIElement</key><true/>' \
	  '</dict>' \
	  '</plist>' > $(APP)/Contents/Info.plist
	@# SMAppService ("Start at login") refuses an unsigned bundle. With the self-signed
	@# identity the designated requirement is pinned to the certificate, so the Input
	@# Monitoring grant survives rebuilds; ad-hoc ties it to the cdhash and resets it.
	@if codesign --force --sign "$(SIGN_IDENTITY)" --timestamp=none $(APP) 2>/dev/null; then \
	  :; \
	else \
	  echo "warning: cannot sign with '$(SIGN_IDENTITY)'; signing ad-hoc (the Input Monitoring grant will reset)"; \
	  codesign --force --sign - $(APP); \
	fi
	@echo "built $(APP)"

# Drawn from code rather than committed as a blob, so it stays reviewable in a diff.
Resources/cuelight.icns: Tools/make-icon.swift
	@mkdir -p build Resources
	swiftc -O Tools/make-icon.swift -o build/make-icon
	@./build/make-icon Resources/cuelight.iconset
	@iconutil -c icns Resources/cuelight.iconset -o $@

## run the checks
test: build/tests
	@./build/tests

build/tests: $(CORE) Tests/main.swift
	@mkdir -p build
	swiftc -O $(CORE) Tests/main.swift -o $@

## build, install into /Applications and PATH, relaunch
install: build
	@# A running copy would keep hold of the LEDs after its bundle is replaced.
	@pkill -f '/cuelight.app/Contents/MacOS/cuelight' 2>/dev/null || true
	@sleep 1
	rm -rf /Applications/cuelight.app
	cp -R $(APP) /Applications/cuelight.app
	@mkdir -p $(PREFIX)/bin $(COMPDIR)
	ln -sf /Applications/cuelight.app/Contents/MacOS/cuelight $(PREFIX)/bin/cuelight
	@# Remove first: the destination may be a symlink back to this very file.
	@rm -f $(COMPDIR)/_cuelight
	cp completions/_cuelight $(COMPDIR)/_cuelight
	@# A certificate-signed bundle keeps the Input Monitoring grant across rebuilds.
	@# An ad-hoc one changes its cdhash every build, so the old grant no longer
	@# applies and macOS will not re-ask by itself: clearing it restores the prompt.
	@if codesign -dvvv $(APP) 2>&1 | grep -qF "Authority=$(SIGN_IDENTITY)"; then \
	  echo "signed with '$(SIGN_IDENTITY)': the Input Monitoring grant is kept"; \
	else \
	  echo "ad-hoc build: clearing the Input Monitoring grant so macOS asks again"; \
	  tccutil reset ListenEvent $(BUNDLE) >/dev/null 2>&1 || true; \
	fi
	@open /Applications/cuelight.app
	@echo
	@echo "installed: /Applications/cuelight.app"
	@echo "cli:       $(PREFIX)/bin/cuelight"

## remove everything but ~/.config/cuelight
uninstall:
	@echo "untick the agent hooks in the menu first, or the hooks stay behind"
	@pkill -f '/cuelight.app/Contents/MacOS/cuelight' 2>/dev/null || true
	rm -rf /Applications/cuelight.app
	rm -f $(PREFIX)/bin/cuelight $(COMPDIR)/_cuelight
	@echo "config left at ~/.config/cuelight -- remove it by hand if you mean it"

## zip the bundle for a GitHub release
release: build
	@cp -R completions build/completions
	@cd build && zip -qr cuelight-$(VERSION).zip cuelight.app completions
	@echo "release: build/cuelight-$(VERSION).zip"
	@echo "sha256:  $$(shasum -a 256 build/cuelight-$(VERSION).zip | cut -d' ' -f1)"

## run the built app without installing it
run: build
	@open $(APP)

## throw away build output
clean:
	rm -rf build

help:
	@awk '/^## /{doc=substr($$0,4);next} \
	      /^[a-z][a-z-]*:/{if(doc){split($$0,t,":");printf "  make %-11s %s\n",t[1],doc;doc=""}}' Makefile
