.PHONY: all build app run clean icon sign

APP_NAME   := TorDrop
BUILD_DIR  := .build/release
APP_BUNDLE := $(APP_NAME).app
LOGO       := Resources/AppIcon.png
ICONSET_SRC := Resources/AppIcon.iconset
ICONSET_FILES := $(wildcard $(ICONSET_SRC)/icon_*.png)
ICONSET    := .build/AppIcon.iconset
ICNS       := .build/AppIcon.icns
CODESIGN_IDENTITY ?= -
CODESIGN_FLAGS := --force --deep --options runtime
SWIFT_ENV := env CLANG_MODULE_CACHE_PATH=.build/ModuleCache

ifneq ($(CODESIGN_IDENTITY),-)
CODESIGN_FLAGS += --timestamp
endif

all: app

build:
	swift build -c release

icon: $(ICNS)

$(ICNS): $(LOGO) $(ICONSET_FILES) Scripts/normalize_icon_pngs.swift
	@rm -rf $(ICONSET)
	@mkdir -p $(ICONSET)
	cp $(ICONSET_SRC)/icon_*.png $(ICONSET)/
	$(SWIFT_ENV) swift Scripts/normalize_icon_pngs.swift $(ICONSET)/icon_*.png
	iconutil -c icns $(ICONSET) -o $(ICNS)

app: build icon
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp $(ICNS) $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	$(MAKE) sign
	@echo "Built $(APP_BUNDLE)"

sign:
	codesign $(CODESIGN_FLAGS) --sign "$(CODESIGN_IDENTITY)" $(APP_BUNDLE)
	codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)

run: app
	open $(APP_BUNDLE)

clean:
	rm -rf .build $(APP_BUNDLE)
