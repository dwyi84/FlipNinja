APP_NAME      := FlipNinja
BUNDLE_ID     := com.melissasoft.FlipNinja
CONFIGURATION ?= release
DIST          := dist
BUILD_DIR     := build
APP           := $(DIST)/$(APP_NAME).app
INSTALL_DIR   ?= $(HOME)/Applications
SWIFT         := swift
VERSION       := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

.PHONY: all build bundle sign verify zip run install uninstall clean icon

all: bundle

## Compile the Swift package (release by default).
build:
	@if [ "$$(uname -m)" != "arm64" ]; then \
		echo "$(APP_NAME) requires Apple Silicon (arm64)."; \
		exit 1; \
	fi
	$(SWIFT) build -c $(CONFIGURATION)

## Assemble and sign dist/FlipNinja.app.
bundle: build Resources/AppIcon.icns
	@BIN="$$($(SWIFT) build -c $(CONFIGURATION) --show-bin-path)/$(APP_NAME)"; \
	echo "==> Assembling $(APP_NAME).app..."; \
	rm -rf "$(APP)"; \
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"; \
	cp "$$BIN" "$(APP)/Contents/MacOS/$(APP_NAME)"; \
	cp "Resources/Info.plist" "$(APP)/Contents/Info.plist"; \
	cp "Resources/AppIcon.icns" "$(APP)/Contents/Resources/AppIcon.icns"; \
	./Scripts/sign.sh "$(APP)"

sign: bundle

## Verify the bundle's signature and Gatekeeper assessment.
verify: bundle
	codesign --verify --strict --verbose=2 "$(APP)"
	@codesign -d --requirements - "$(APP)" 2>/dev/null | grep -oE 'designated =>.*' || true

## Package dist/FlipNinja-<version>.zip for a GitHub release / Homebrew cask.
zip: bundle
	@ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(DIST)/$(APP_NAME)-$(VERSION).zip"
	@echo "==> Wrote $(DIST)/$(APP_NAME)-$(VERSION).zip"

## Build and launch the bundle from dist/ (development flow).
run: bundle
	open "$(APP)"
	@echo ""
	@echo "$(APP_NAME) is running in the menu bar."
	@echo "Click the laptop icon to open the panel; right-click for quick actions."

## Install into ~/Applications (override with INSTALL_DIR=/Applications).
install: bundle
	@osascript -e 'tell application "$(APP_NAME)" to quit' >/dev/null 2>&1 || true
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@ditto "$(APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "==> Installed $(INSTALL_DIR)/$(APP_NAME).app"
	@open "$(INSTALL_DIR)/$(APP_NAME).app"

uninstall:
	@osascript -e 'tell application "$(APP_NAME)" to quit' >/dev/null 2>&1 || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "==> Removed $(INSTALL_DIR)/$(APP_NAME).app"

## Regenerate Resources/AppIcon.icns from the SwiftUI artwork.
icon:
	@mkdir -p "$(BUILD_DIR)"
	swiftc -O Scripts/make_appicon.swift Sources/FlipNinja/FlipNinjaIconView.swift \
		-o "$(BUILD_DIR)/make_appicon"
	@"$(BUILD_DIR)/make_appicon" "$(BUILD_DIR)/AppIcon-1024.png"
	@rm -rf "$(BUILD_DIR)/AppIcon.iconset"
	@mkdir -p "$(BUILD_DIR)/AppIcon.iconset"
	@for size in 16 32 128 256 512; do \
		d=$$((size * 2)); \
		sips -z $$size $$size "$(BUILD_DIR)/AppIcon-1024.png" \
			--out "$(BUILD_DIR)/AppIcon.iconset/icon_$${size}x$${size}.png" >/dev/null; \
		sips -z $$d $$d "$(BUILD_DIR)/AppIcon-1024.png" \
			--out "$(BUILD_DIR)/AppIcon.iconset/icon_$${size}x$${size}@2x.png" >/dev/null; \
	done
	@iconutil -c icns "$(BUILD_DIR)/AppIcon.iconset" -o "Resources/AppIcon.icns"
	@echo "==> Wrote Resources/AppIcon.icns"

Resources/AppIcon.icns: Scripts/make_appicon.swift Sources/FlipNinja/FlipNinjaIconView.swift
	@$(MAKE) --no-print-directory icon

clean:
	rm -rf "$(BUILD_DIR)"
	$(SWIFT) package clean
	rm -rf .build "$(DIST)"
