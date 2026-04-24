.PHONY: all build app run clean icon sign

APP_NAME   := TorDrop
BUILD_DIR  := .build/release
APP_BUNDLE := $(APP_NAME).app
LOGO       := Resources/AppIcon.png
ICONSET    := .build/AppIcon.iconset
ICNS       := .build/AppIcon.icns
CODESIGN_IDENTITY ?= -
CODESIGN_FLAGS := --force --deep --options runtime

ifneq ($(CODESIGN_IDENTITY),-)
CODESIGN_FLAGS += --timestamp
endif

all: app

build:
	swift build -c release

icon: $(ICNS)

$(ICNS): $(LOGO)
	@rm -rf $(ICONSET)
	@mkdir -p $(ICONSET)
	sips -z 16 16     $(LOGO) --out $(ICONSET)/icon_16x16.png       >/dev/null
	sips -z 32 32     $(LOGO) --out $(ICONSET)/icon_16x16@2x.png    >/dev/null
	sips -z 32 32     $(LOGO) --out $(ICONSET)/icon_32x32.png       >/dev/null
	sips -z 64 64     $(LOGO) --out $(ICONSET)/icon_32x32@2x.png    >/dev/null
	sips -z 128 128   $(LOGO) --out $(ICONSET)/icon_128x128.png     >/dev/null
	sips -z 256 256   $(LOGO) --out $(ICONSET)/icon_128x128@2x.png  >/dev/null
	sips -z 256 256   $(LOGO) --out $(ICONSET)/icon_256x256.png     >/dev/null
	sips -z 512 512   $(LOGO) --out $(ICONSET)/icon_256x256@2x.png  >/dev/null
	sips -z 512 512   $(LOGO) --out $(ICONSET)/icon_512x512.png     >/dev/null
	cp $(LOGO) $(ICONSET)/icon_512x512@2x.png
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
