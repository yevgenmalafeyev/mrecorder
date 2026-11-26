# Build, sign with the stable local identity, install to ~/Applications and run.
# Signing with the same certificate every time keeps the Screen Recording permission across rebuilds.
SIGN_ID ?= Apple Development
APP      = build.noindex/Build/Products/Release/MacRecorder.app
DEST     = $(HOME)/Applications/MacRecorder.app

.PHONY: gen build sign install run test clean logs icon dist

gen:
	xcodegen generate --quiet

build: gen
	xcodebuild -project MacRecorder.xcodeproj -scheme MacRecorder -configuration Release \
		-derivedDataPath build.noindex CODE_SIGNING_ALLOWED=NO -quiet build

sign: build
	codesign --force --options runtime --timestamp=none \
		--entitlements App/MacRecorder.entitlements --sign "$(SIGN_ID)" $(APP)

install: sign
	-pkill -x MacRecorder; sleep 0.5
	mkdir -p $(HOME)/Applications
	rm -rf $(DEST) && cp -R $(APP) $(DEST)

run: install
	open $(DEST)

test:
	cd Packages/RecorderCore && swift test

logs:
	log stream --style compact --predicate 'subsystem == "local.macrecorder.MacRecorder"'

clean:
	rm -rf build.noindex build MacRecorder.xcodeproj

# Universal (Apple Silicon + Intel) DMG for a GitHub release: build.noindex/dist/MacRecorder-<version>.dmg
VERSION := $(shell sed -nE 's/.*MARKETING_VERSION: "(.*)"/\1/p' project.yml)
DIST     = build.noindex/dist
DMG      = $(DIST)/MacRecorder-$(VERSION).dmg

dist: gen
	xcodebuild -project MacRecorder.xcodeproj -scheme MacRecorder -configuration Release \
		-derivedDataPath build.noindex CODE_SIGNING_ALLOWED=NO ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build
	codesign --force --options runtime --timestamp \
		--entitlements App/MacRecorder.entitlements --sign "$(SIGN_ID)" $(APP)
	rm -rf $(DIST)
	mkdir -p $(DIST)/root
	cp -R $(APP) $(DIST)/root/
	ln -s /Applications $(DIST)/root/Applications
	hdiutil create -quiet -volname "MacRecorder $(VERSION)" -srcfolder $(DIST)/root -fs HFS+ -format UDZO $(DMG)
	rm -rf $(DIST)/root
	@echo "Built $(DMG)"

# Regenerate App/AppIcon.icns from Tools/make-icon.swift
ICONDIR = build.noindex/icon
icon:
	mkdir -p $(ICONDIR)/AppIcon.iconset
	swift Tools/make-icon.swift $(ICONDIR)/icon.png
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s $(ICONDIR)/icon.png --out $(ICONDIR)/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		d=$$((s*2)); sips -z $$d $$d $(ICONDIR)/icon.png --out $(ICONDIR)/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns $(ICONDIR)/AppIcon.iconset -o App/AppIcon.icns
