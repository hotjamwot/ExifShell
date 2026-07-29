# ExifShell Makefile
# Build, install, and run without opening Xcode.
#
# Usage:
#   make          — build Release and copy to ~/Downloads, then open
#   make build    — build Release only
#   make install  — copy the built .app to ~/Downloads
#   make run      — open the app from ~/Downloads
#   make release  — copy the built .app to /Applications (for final releases)
#   make clean    — remove the app from ~/Downloads

PROJECT = ExifShell.xcodeproj
SCHEME  = ExifShell
CONFIG  = Release

# xcodebuild puts the .app in DerivedData under a hash-based path.
# We use xcodebuild's -showBuildSettings to locate it dynamically.
BUILD_DIR = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -showBuildSettings 2>/dev/null | grep '^ *BUILT_PRODUCTS_DIR' | awk '{print $$NF}')
APP      = ExifShell.app
DST      = $(HOME)/Downloads/$(APP)

.PHONY: all build install run release clean

all: build install run

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) build

install: build
	@if [ -d "$(DST)" ]; then rm -rf "$(DST)"; fi
	cp -R "$(BUILD_DIR)/$(APP)" "$(DST)"
	@echo "Installed to $(DST)"

run: install
	open "$(DST)"

release: build
	@if [ -d "/Applications/$(APP)" ]; then \
		echo "Removing previous /Applications/$(APP)..."; \
		sudo rm -rf "/Applications/$(APP)"; \
	fi
	sudo cp -R "$(BUILD_DIR)/$(APP)" "/Applications/"
	@echo "Installed to /Applications/$(APP)"

clean:
	@if [ -d "$(DST)" ]; then rm -rf "$(DST)" && echo "Removed $(DST)"; fi