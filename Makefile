APP_NAME    := TermIMS
BUILD_DIR   := build
BUNDLE      := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := /Applications/$(APP_NAME).app
DIST_DIR    := dist

.PHONY: build install run dist clean

build:
	@bash Scripts/package-app.sh

install: build
	@pkill -x $(APP_NAME) 2>/dev/null && sleep 0.3 || true
	@rm -rf $(INSTALL_DIR)
	@cp -a $(BUNDLE) $(INSTALL_DIR)
	@echo "Installed → $(INSTALL_DIR)"

run: install
	@open $(INSTALL_DIR)
	@echo "Running"

dist: build
	@rm -rf $(BUILD_DIR)/dmg-staging $(DIST_DIR)
	@mkdir -p $(BUILD_DIR)/dmg-staging $(DIST_DIR)
	@cp -a $(BUNDLE) $(BUILD_DIR)/dmg-staging/
	@ln -s /Applications $(BUILD_DIR)/dmg-staging/Applications
	@hdiutil create -volname $(APP_NAME) -srcfolder $(BUILD_DIR)/dmg-staging -ov -format UDZO $(DIST_DIR)/$(APP_NAME).dmg -quiet
	@rm -rf $(BUILD_DIR)/dmg-staging
	@echo "Packaged → $(DIST_DIR)/$(APP_NAME).dmg"

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR) .build .swiftpm
