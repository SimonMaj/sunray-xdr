PREFIX ?= /usr/local
BINARY = sunray-xdr
BUILD_DIR = .build
APP_NAME = Sunray XDR
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
APP_EXECUTABLE = SunrayXDR

.PHONY: all build app open install uninstall clean launch-agent remove-agent

all: app

build:
	@mkdir -p $(BUILD_DIR)
	swiftc -O -o $(BUILD_DIR)/$(BINARY) Sources/main.swift \
		-framework Cocoa -framework SwiftUI -framework MetalKit -framework Metal

app: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp Packaging/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp Packaging/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	cp "$(BUILD_DIR)/$(BINARY)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_EXECUTABLE)"
	chmod 755 "$(APP_BUNDLE)/Contents/MacOS/$(APP_EXECUTABLE)"
	@codesign --force --deep --sign - "$(APP_BUNDLE)" >/dev/null
	@echo "Built $(APP_BUNDLE)"

open: app
	open "$(APP_BUNDLE)"

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BUILD_DIR)/$(BINARY) $(PREFIX)/bin/$(BINARY)

uninstall: remove-agent
	rm -f $(PREFIX)/bin/$(BINARY)

# Install LaunchAgent to start on login
launch-agent: install
	@mkdir -p ~/Library/LaunchAgents
	@sed "s|__BINARY__|$(PREFIX)/bin/$(BINARY)|g" \
		com.sunray-xdr.agent.plist > ~/Library/LaunchAgents/com.sunray-xdr.agent.plist
	launchctl load ~/Library/LaunchAgents/com.sunray-xdr.agent.plist
	@echo "sunray-xdr will now start on login"

remove-agent:
	-launchctl unload ~/Library/LaunchAgents/com.sunray-xdr.agent.plist 2>/dev/null
	rm -f ~/Library/LaunchAgents/com.sunray-xdr.agent.plist

clean:
	rm -rf $(BUILD_DIR)
