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
# The app's package versions, committed (the project isn't). Xcode reads them from inside the
# project, where `pin` puts them; MixdownKit/Package.resolved only pins the package's own graph.
RESOLVED      := Mixdown.resolved
PROJECT_RESOLVED := $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
# The full output of the last `make build`, which ends with a summary of its errors when it fails.
BUILD_LOG     := build/xcodebuild.log
# Bash for `pipefail`, so a failing xcodebuild isn't hidden by the `tee` after it.
SHELL         := /bin/bash
LSREGISTER    := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# `make install` builds the Release configuration here, apart from the Debug builds in DerivedData,
# and copies it to INSTALL_DIR, where every account on this Mac can open it.
RELEASE_DIR   := build/release
RELEASE_APP   := $(RELEASE_DIR)/Build/Products/Release/Mixdown.app
INSTALL_DIR   ?= /Applications
# `make install-cli` puts the `mixdown` command here, and `make install-skill` the agent skill
# (skills/mixdown) in a folder of SKILL_DIR, which is Claude Code's; Codex reads ~/.codex/skills.
CLI           := MixdownKit/.build/release/mixdown
BIN_DIR       ?= /usr/local/bin
SKILL_DIR     ?= $(HOME)/.claude/skills

# Shell snippet printing one of the scheme's build settings, e.g. $(call setting,BUILD_DIR).
# Builds go to Xcode's global DerivedData, so this is how to find them.
setting = $$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination $(DESTINATION) $(XCODEBUILD_FLAGS) \
	-showBuildSettings 2>/dev/null | awk -F" = " '/ $(1) /{print $$2; exit}')

.PHONY: bootstrap project pin resolve open build run install cli install-cli install-skill logs test format lint ci clean

## Install XcodeGen (Homebrew) and the Metal Toolchain MLX needs. swift-format ships with Xcode.
bootstrap:
	@command -v xcodegen >/dev/null || brew install xcodegen
	@xcrun metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain

## Generate Mixdown.xcodeproj from project.yml.
project:
	xcodegen generate
	@$(MAKE) --no-print-directory pin

## Put the committed package versions where Xcode reads them, so every checkout builds the app
## with the same ones.
pin:
	@mkdir -p $(dir $(PROJECT_RESOLVED))
	@cp $(RESOLVED) $(PROJECT_RESOLVED)

## Update the app's packages to the newest versions project.yml allows, and commit what changed
## in Mixdown.resolved.
resolve: $(PBXPROJ)
	rm -f $(PROJECT_RESOLVED)
	xcodebuild -resolvePackageDependencies -project $(PROJECT) -scheme $(SCHEME) $(XCODEBUILD_FLAGS)
	cp $(PROJECT_RESOLVED) $(RESOLVED)

open: $(PBXPROJ)
	open $(PROJECT)

# Builds the scheme with xcodebuild, passing it $(1) as extra arguments. On failure, lists each
# compiler error once with the source lines around it. xcodebuild's own summary only names the
# failed steps, and the errors are buried far above it (often twice).
define xcodebuild
	@mkdir -p $(dir $(BUILD_LOG))
	@set -o pipefail; \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination $(DESTINATION) $(XCODEBUILD_FLAGS) $(1) build \
		2>&1 | tee $(BUILD_LOG) || { \
		echo; echo "=== Errors ==="; \
		awk '/: error:/ { skip = ($$0 in seen); seen[$$0] = 1; left = 8 } left > 0 { if (!skip) print; left-- }' $(BUILD_LOG); \
		echo; echo "Full log: $(BUILD_LOG)"; \
		exit 1; \
	}
endef

build: $(PBXPROJ)
	$(call xcodebuild,)

## Build, then launch the app.
run: build
	open "$(call setting,BUILT_PRODUCTS_DIR)/Mixdown.app"

## Build the Release configuration (Apple Silicon only, like the app) and install it in
## INSTALL_DIR (/Applications), replacing the copy there. Asks for your password to copy it. Release
## builds have no Sparkle key, so they don't update themselves: run this again to update.
install: $(PBXPROJ)
	$(call xcodebuild,-configuration Release -derivedDataPath $(RELEASE_DIR) ARCHS=arm64)
	@osascript -e 'if application id "$(BUNDLE_ID)" is running then tell application id "$(BUNDLE_ID)" to quit' 2>/dev/null || true
	sudo rm -rf "$(INSTALL_DIR)/Mixdown.app"
	sudo ditto "$(RELEASE_APP)" "$(INSTALL_DIR)/Mixdown.app"
	@$(LSREGISTER) -f "$(INSTALL_DIR)/Mixdown.app"
	@echo "Installed $(INSTALL_DIR)/Mixdown.app"

## Build the `mixdown` command-line tool. It only needs MixdownCore and MixdownNotes, not the
## models, so it builds with SwiftPM alone.
cli:
	cd MixdownKit && swift build -c release --product mixdown

## Install the `mixdown` command in BIN_DIR (/usr/local/bin), asking for your password if that
## folder isn't yours.
install-cli: cli
	@if [ -w "$(BIN_DIR)" ]; then install -m 755 $(CLI) "$(BIN_DIR)/mixdown"; \
	else sudo install -d "$(BIN_DIR)" && sudo install -m 755 $(CLI) "$(BIN_DIR)/mixdown"; fi
	@echo "Installed $(BIN_DIR)/mixdown"

## Install the agent skill that teaches AI agents to use `mixdown`, in SKILL_DIR/mixdown
## (~/.claude/skills/mixdown).
install-skill:
	@mkdir -p "$(SKILL_DIR)/mixdown"
	cp skills/mixdown/SKILL.md "$(SKILL_DIR)/mixdown/SKILL.md"

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

## What CI checks on every push and pull request; see .github/workflows/ci.yml.
ci: lint test

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
$(PBXPROJ): project.yml $(RESOLVED) $(shell find Mixdown -type f)
	xcodegen generate
	@$(MAKE) --no-print-directory pin
	@touch $@
