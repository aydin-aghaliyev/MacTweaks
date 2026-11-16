APP     := build/MacTweaks.app
CONFIG  ?= release
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: all build app run install signing clean

all: app

build:
	swift build -c $(CONFIG)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Resources/Info.plist $(APP)/Contents/
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/MacTweaks" $(APP)/Contents/MacOS/
	scripts/sign.sh $(APP)

run: app
	-pkill -x MacTweaks
	open $(APP)

install: app
	-pkill -x MacTweaks
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/MacTweaks.app"
	cp -R $(APP) "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/MacTweaks.app"

signing:
	scripts/make-signing-identity.sh

clean:
	rm -rf .build build
