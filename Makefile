SWIFT ?= swift

# Command Line Tools only (no Xcode): Swift Testing lives outside the default
# search paths, and Testing.framework needs lib_TestingInterop.dylib at runtime.
CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer
TEST_FLAGS := -Xswiftc -F$(CLT_DEV)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib

APP := build/DesktopAutomata.app

.PHONY: build test app run clean

build:
	$(SWIFT) build

test:
	$(SWIFT) test $(TEST_FLAGS)

app:
	./scripts/bundle.sh

run: app
	open "$(APP)"

clean:
	rm -rf .build build
