APP        := IMSwitch.app
BIN        := $(APP)/Contents/MacOS/IMSwitch
INSTALL_DIR := /Applications
SRC        := IMSwitch.swift
PLIST      := Info.plist
FRAMEWORKS := -framework Cocoa -framework Carbon

.PHONY: build install clean restart

build: $(BIN)

$(BIN): $(SRC) $(PLIST)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp $(PLIST) $(APP)/Contents/
	swiftc -O -o $@ $(SRC) $(FRAMEWORKS)
	@echo "Built → $(APP)"

install: build
	@rm -rf $(INSTALL_DIR)/$(APP)
	@cp -a $(APP) $(INSTALL_DIR)/
	@echo "Installed → $(INSTALL_DIR)/$(APP)"

restart: install
	@pkill -x IMSwitch 2>/dev/null; sleep 1; open $(INSTALL_DIR)/$(APP)
	@echo "Restarted"

clean:
	rm -rf $(APP)
