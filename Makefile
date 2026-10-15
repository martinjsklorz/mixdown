SCHEME        := Mixdown
PROJECT       := Mixdown.xcodeproj
PBXPROJ       := $(PROJECT)/project.pbxproj
SWIFT_FORMAT  ?= xcrun swift-format
FORMAT_PATHS  := Mixdown MixdownKit/Sources MixdownKit/Tests MixdownKit/Package.swift
DESTINATION   := 'platform=macOS,arch=arm64'
# xcodebuild can't show Xcode's "Trust & Enable" prompt for package plugins/macros (e.g.
# mlx-swift's CudaBuild plugin), so skip validation for command-line builds.
XCODEBUILD_FLAGS := -skipPackagePluginValidation -skipMacroValidation
BUNDLE_ID     := app.mixdown.Mixdown
# The full output of the last `make build`, which ends with a summary of its errors when it fails.
BUILD_LOG     := build/xcodebuild.log
# Bash for `pipefail`, so a failing xcodebuild isn't hidden by the `tee` after it.
SHELL         := /bin/bash
LSREGISTER    := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Shell snippet printing one of the scheme's build settings, e.g. $(call setting,BUILD_DIR).
# Builds go to Xcode's global DerivedData, so this is how to find them.
setting = $$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination $(DESTINATION) $(XCODEBUILD_FLAGS) \
	-showBuildSettings 2>/dev/null | awk -F" = " '/ $(1) /{print $$2; exit}')

.PHONY: bootstrap project open build run logs test format lint clean

## Install XcodeGen (Homebrew) and the Metal Toolchain MLX needs. swift-format ships with Xcode.
bootstrap:
	@command -v xcodegen >/dev/null || brew install xcodegen
	@xcrun metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain

## Generate Mixdown.xcodeproj from project.yml.
project:
	xcodegen generate

open: $(PBXPROJ)
	open $(PROJECT)

## On failure, lists each compiler error once with the source lines around it. xcodebuild's own
## summary only names the failed steps, and the errors are buried far above it (often twice).
build: $(PBXPROJ)
	@mkdir -p $(dir $(BUILD_LOG))
	@set -o pipefail; \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination $(DESTINATION) $(XCODEBUILD_FLAGS) build \
		2>&1 | tee $(BUILD_LOG) || { \
		echo; echo "=== Errors ==="; \
		awk '/: error:/ { skip = ($$0 in seen); seen[$$0] = 1; left = 8 } left > 0 { if (!skip) print; left-- }' $(BUILD_LOG); \
		echo; echo "Full log: $(BUILD_LOG)"; \
		exit 1; \
	}

## Build, then launch the app.
run: build
	open "$(call setting,BUILT_PRODUCTS_DIR)/Mixdown.app"

## Follow the app's log output (os.Logger, subsystem app.mixdown).
logs:
	log stream --level debug --predicate 'subsystem == "app.mixdown"'

## Runs the MixdownKit package tests (no Xcode project needed). They never load an MLX model,
## so the missing metallib in plain SwiftPM builds doesn't matter here.
test:
	cd MixdownKit && swift test

format:
	$(SWIFT_FORMAT) format --in-place --recursive --parallel $(FORMAT_PATHS)

lint:
	$(SWIFT_FORMAT) lint --strict --recursive --parallel $(FORMAT_PATHS)

## Quit Mixdown, unregister its builds from Launch Services and delete them (this checkout's
## DerivedData folder), the generated project and the package build. Restarts the Dock so it
## drops its cached copy of the app icon.
clean: $(PBXPROJ)
	@osascript -e 'if application id "$(BUNDLE_ID)" is running then tell application id "$(BUNDLE_ID)" to quit' 2>/dev/null || true
	@build_dir="$(call setting,BUILD_DIR)"; derived="$${build_dir%/Build/Products}"; \
	case "$$derived" in \
	*/DerivedData/Mixdown-*) \
		for app in "$$build_dir"/*/Mixdown.app; do [ -e "$$app" ] && $(LSREGISTER) -u "$$app"; done; \
		echo "rm -rf $$derived"; rm -rf "$$derived";; \
	esac
	rm -rf $(PROJECT) DerivedData MixdownKit/.build build
	killall Dock

# Regenerate when the spec changes or app files are added, removed or edited (XcodeGen
# lists every file explicitly). The touch keeps the stamp fresh if XcodeGen skips writing.
$(PBXPROJ): project.yml $(shell find Mixdown -type f)
	xcodegen generate
	@touch $@
