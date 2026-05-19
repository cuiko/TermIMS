APP_NAME   := TermIMS
BUILD_DIR  := build
BUNDLE     := $(BUILD_DIR)/$(APP_NAME).app
BIN        := $(BUNDLE)/Contents/MacOS/$(APP_NAME)
INSTALL_DIR := /Applications/$(APP_NAME).app
SRC        := TermIMS.swift
PLIST      := Info.plist
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
	@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.5; true
	@rm -rf $(INSTALL_DIR)
	@cp -a $(BUNDLE) $(INSTALL_DIR)
	@echo "Installed → $(INSTALL_DIR)"

restart: install
	@open $(INSTALL_DIR)
	@echo "Restarted"

dist: build
	@rm -rf $(BUILD_DIR)/dist
	@mkdir -p $(BUILD_DIR)/dist
	@cp -a $(BUNDLE) $(BUILD_DIR)/dist/
	@ln -s /Applications $(BUILD_DIR)/dist/Applications
	@hdiutil create -volname $(APP_NAME) -srcfolder $(BUILD_DIR)/dist -ov -format UDZO $(APP_NAME).dmg -quiet
	@rm -rf $(BUILD_DIR)/dist
	@echo "Packaged → $(APP_NAME).dmg"

clean:
	rm -rf $(BUILD_DIR)
