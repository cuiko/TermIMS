APP_NAME   := TermIMS
BUILD_DIR  := build
BUNDLE     := $(BUILD_DIR)/$(APP_NAME).app
BIN        := $(BUNDLE)/Contents/MacOS/$(APP_NAME)
INSTALL_DIR := /Applications/$(APP_NAME).app
SRC        := TermIMS.swift
PLIST      := Info.plist
DIST_DIR   := dist
FRAMEWORKS := -framework Cocoa -framework Carbon

.PHONY: build install clean restart dist

build: $(BIN)

$(BIN): $(SRC) $(PLIST) AppIcon.icns
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp $(PLIST) $(BUNDLE)/Contents/
	@cp AppIcon.icns $(BUNDLE)/Contents/Resources/
	swiftc -O -o $@ $(SRC) $(FRAMEWORKS)
	@codesign --force --sign - $(BUNDLE)
	@echo "Built → $(BUNDLE)"

install: build
	@pkill -x $(APP_NAME) 2>/dev/null && sleep 0.3 || true
	@rm -rf $(INSTALL_DIR)
	@cp -a $(BUNDLE) $(INSTALL_DIR)
	@echo "Installed → $(INSTALL_DIR)"

restart: install
	@open $(INSTALL_DIR)
	@echo "Restarted"

dist: build
	@rm -rf $(BUILD_DIR)/dmg-staging $(DIST_DIR)
	@mkdir -p $(BUILD_DIR)/dmg-staging $(DIST_DIR)
	@cp -a $(BUNDLE) $(BUILD_DIR)/dmg-staging/
	@ln -s /Applications $(BUILD_DIR)/dmg-staging/Applications
	@hdiutil create -volname $(APP_NAME) -srcfolder $(BUILD_DIR)/dmg-staging -ov -format UDZO $(DIST_DIR)/$(APP_NAME).dmg -quiet
	@rm -rf $(BUILD_DIR)/dmg-staging
	@echo "Packaged → $(DIST_DIR)/$(APP_NAME).dmg"

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR)
