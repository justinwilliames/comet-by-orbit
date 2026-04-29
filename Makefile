SCHEME = Whispur
PROJECT = Whispur.xcodeproj
APP_NAME = Orbit Dictation
BUILD_DIR = build
CONFIGURATION = Release
APP_PATH = $(BUILD_DIR)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app

.PHONY: all clean run dev generate

generate:
	xcodegen generate

all: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(BUILD_DIR) \
		build

run: all
	open "$(APP_PATH)"

build-number:
	@VERSION=$$(sed -n 's/.*MARKETING_VERSION: "\([^"]*\)".*/\1/p' project.yml | head -1); \
	IFS='.' read -r major minor patch <<< "$$VERSION"; \
	echo $$((10#$$major * 10000 + 10#$$minor * 100 + 10#$$patch))

clean:
	rm -rf $(BUILD_DIR)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true

dev: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Debug \
		-derivedDataPath $(BUILD_DIR) \
		build
