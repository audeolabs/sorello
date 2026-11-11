# Sorello for iPhone, built with swiftc and make (no Xcode project), against
# the package's shared modules, which SwiftPM builds. Run `make -C iOS <target>`
# from the repository root, or `make` in this directory. README.md documents
# usage; ARCHITECTURE.md is the contract.
.DEFAULT_GOAL := all

# dev (the default) or appstore. appstore presets the production identifiers
# and icon for a device build signed for App Store Connect (README.md, "App
# Store build"); every preset can still be overridden.
CHANNEL ?= dev
ifeq ($(CHANNEL),appstore)
PLATFORM ?= device
# Kept from the app's first name, as are the dev values below: an update must replace the app people already have
# (ARCHITECTURE.md, "Identifiers").
BUNDLE_ID ?= com.ajbarryiii.localflow.ios
URL_SCHEME ?= localflow
UNIVERSAL_LINK ?= https://wildernesslabs.ai/localflow/dictate
DISPLAY_NAME ?= Sorello
ICON_SOURCE ?= Resources/AppIcon-Source.png
BUILD_DIR ?= build/appstore
ifneq ($(PLATFORM),device)
$(error CHANNEL=appstore needs PLATFORM=device)
endif
ifneq ($(findstring SORELLO_SELFTEST,$(SWIFT_FLAGS)),)
$(error CHANNEL=appstore never builds the self-test variant)
endif
else ifneq ($(CHANNEL),dev)
$(error CHANNEL must be dev or appstore)
endif
# Optional CFBundleVersion for every bundle, which App Store Connect requires to
# grow with every upload of a version; empty keeps the template's.
BUILD_NUMBER ?=
ifneq ($(strip $(BUILD_NUMBER)),)
ifneq ($(shell printf '%s' '$(BUILD_NUMBER)' | grep -Ex '[0-9]+(\.[0-9]+){0,2}'),$(BUILD_NUMBER))
$(error BUILD_NUMBER must be one to three dot-separated integers)
endif
endif

PLATFORM ?= simulator
# Kept from the app's first name, as the App Store values above.
BUNDLE_ID ?= com.ajbarryiii.localflow.ios.dev
KEYBOARD_BUNDLE_ID = $(BUNDLE_ID).keyboard
ACTIVITY_BUNDLE_ID = $(BUNDLE_ID).activity
APP_GROUP ?= group.$(BUNDLE_ID)
URL_SCHEME ?= localflow-dev
# The https URL the keyboard opens instead of <scheme>://dictate, universal-links-only, so iOS opens
# only the app verified for its domain. The app is then signed with the Associated Domains
# entitlement for its host, which its profile must grant. Empty (dev, simulator, self-test and e2e
# builds) keeps the scheme; https://wildernesslabs.ai/localflow-dev/dictate is the dev device opt-in.
UNIVERSAL_LINK ?=
DISPLAY_NAME ?= Sorello Dev
DEPLOYMENT_TARGET ?= 26.0
# A local copy of the speech model's build that ../Models/model.lock.json lists for iOS: the directory holding its
# bundle.json, as SORELLO_MODEL_DIR is for the Mac app. The build checks it against the pin and its manifest and copies
# exactly the manifest's files into Sorello.app/Model/, with the pin and the model's notices. Empty builds an app
# without the model, which cannot transcribe. The weights stay outside Git.
SORELLO_MODEL_DIR ?=
# Optional swipe typing bundle (SwipeEncoder.mlmodelc, lexicon.bin, bundle.json);
# empty builds a keyboard without swipe typing.
SWIPE_BUNDLE_DIR ?=
TEAM_ID ?=
APP_PROFILE ?=
KEYBOARD_PROFILE ?=
ACTIVITY_PROFILE ?=
BUILD_DIR ?= build/$(PLATFORM)
SWIFT_FLAGS ?=
# Optional keychain holding the signing identity (device builds signed over SSH).
CODESIGN_KEYCHAIN ?=
CODESIGN_KEYCHAIN_FLAG = $(if $(strip $(CODESIGN_KEYCHAIN)),--keychain "$(CODESIGN_KEYCHAIN)")
SWIFT_OPTIMIZATION ?= $(if $(strip $(SORELLO_MODEL_DIR)),-O,-Onone)
ICON_SOURCE ?= Resources/AppIcon-Dev-Source.png
PYTHON ?= python3

# A value as one single-quoted shell word, spaces and quotes kept (subst does not
# collapse whitespace): for paths handed to the shell whole, as in clean.
shell_quote = '$(subst ','\'',$(1))'

# https://<host>/<path> with no user, port, query, fragment or trailing slash. App Store builds
# need one.
ifneq ($(strip $(UNIVERSAL_LINK)),)
ifneq ($(shell printf '%s' $(call shell_quote,$(UNIVERSAL_LINK)) | grep -Ex 'https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(/[A-Za-z0-9._~-]+)+'),$(UNIVERSAL_LINK))
$(error UNIVERSAL_LINK must be https://<host>/<path>, with no port, query, fragment or trailing slash)
endif
else ifeq ($(CHANNEL),appstore)
$(error CHANNEL=appstore needs UNIVERSAL_LINK, an https URL)
endif
UNIVERSAL_LINK_HOST = $(word 2,$(subst /, ,$(UNIVERSAL_LINK)))

ifeq ($(PLATFORM),simulator)
SDK = iphonesimulator
SUPPORTED_PLATFORM = iPhoneSimulator
TARGET = arm64-apple-ios$(DEPLOYMENT_TARGET)-simulator
CODESIGN_IDENTITY ?= -
ifneq ($(filter install-device,$(MAKECMDGOALS)),)
$(error install-device needs PLATFORM=device)
endif
ifneq ($(filter ipa appstore-check appstore-validate appstore-upload,$(MAKECMDGOALS)),)
$(error $(filter ipa appstore-check appstore-validate appstore-upload,$(MAKECMDGOALS)) needs PLATFORM=device (or CHANNEL=appstore))
endif
else ifeq ($(PLATFORM),device)
SDK = iphoneos
SUPPORTED_PLATFORM = iPhoneOS
TARGET = arm64-apple-ios$(DEPLOYMENT_TARGET)
CODESIGN_IDENTITY ?=
ifneq ($(filter install-sim run-sim,$(MAKECMDGOALS)),)
$(error install-sim and run-sim need PLATFORM=simulator)
endif
else
$(error PLATFORM must be simulator or device)
endif
SDK_PATH := $(shell xcrun --sdk $(SDK) --show-sdk-path)
SDK_VERSION := $(shell xcrun --sdk $(SDK) --show-sdk-version)
# What Xcode records in every Info.plist; App Store Connect checks it against its
# minimum toolchain. Xcode 26.4.1 is DTXcode 2641.
SDK_BUILD := $(shell xcrun --sdk $(SDK) --show-sdk-build-version)
XCODE_VERSION := $(shell xcodebuild -version 2>/dev/null | awk '/^Xcode / { print $$2 }')
XCODE_BUILD := $(shell xcodebuild -version 2>/dev/null | awk '/^Build version / { print $$3 }')
DT_XCODE := $(shell printf '%s\n' '$(XCODE_VERSION)' | awk -F. 'NF { printf "%02d%d%d", $$1, $$2, $$3 }')
BUILD_MACHINE_OS_BUILD := $(shell sw_vers -buildVersion 2>/dev/null)

# Every list can be overridden, e.g. `make SHARED_SOURCES= HOSTCORE_SOURCES=`. The shared modules are not
# among them: they come from the package (PACKAGE_SOURCES, below).
swift_sources = $(shell find $(1) -name '*.swift' -type f 2>/dev/null | LC_ALL=C sort)
APP_SWIFT_SOURCES ?= $(call swift_sources,App)
KEYBOARD_SWIFT_SOURCES ?= $(call swift_sources,Keyboard)
# The session's Live Activity (ARCHITECTURE.md, "Live Activity"): the widget extension's views in Activity/, the
# content state in ActivityCore/ (also the app's and the tests'), and the attributes, which the app requests.
ACTIVITY_SWIFT_SOURCES ?= $(call swift_sources,Activity)
ACTIVITYCORE_SOURCES ?= $(call swift_sources,ActivityCore)
ACTIVITY_ATTRIBUTES_SOURCES ?= Activity/SessionActivityAttributes.swift
# The session control's App Intent (ARCHITECTURE.md, "Session control"): the app performs it, the extension's control
# names it, and both bundles carry its App Intents metadata.
SESSION_CONTROL_INTENT_SOURCES ?= Activity/SessionControlIntent.swift
# The ridge mark, drawn as the keyboard draws it; KeyboardLayout has its box type; DotWave the swell the strip shares with
# the keyboard's wave. All are Foundation only.
ACTIVITY_KEYBOARDCORE_SOURCES ?= KeyboardCore/RidgeMark.swift KeyboardCore/KeyboardLayout.swift KeyboardCore/DotWave.swift
# The app draws the same mark and wave (the session card, onboarding and the start-session screen).
APP_KEYBOARDCORE_SOURCES ?= $(ACTIVITY_KEYBOARDCORE_SOURCES)
# The display face, Urbanist Medium (SIL OFL 1.1), the repository's one copy, with its license beside it (`UIAppFonts`).
APP_FONTS ?= ../Resources/Fonts/Urbanist-Medium.ttf ../Resources/Fonts/Urbanist-OFL.txt
SHARED_SOURCES ?= $(call swift_sources,Shared)
HOSTCORE_SOURCES ?= $(call swift_sources,HostCore)
KEYBOARDCORE_SOURCES ?= $(call swift_sources,KeyboardCore)
TEST_SOURCES ?= $(call swift_sources,Tests)
# The swipe engine is Foundation and Core ML only; the host tests drive it with a fake encoder. The
# autocorrect loader is Foundation only; the host tests load invented bundles with it. The keyboard's
# messages and model loader are Foundation only.
KEYBOARD_TEST_SOURCES ?= Keyboard/SwipeEngine.swift Keyboard/AutocorrectLoader.swift Keyboard/KeyboardMessages.swift \
	Keyboard/BundleModelLoader.swift
APP_SOURCES = $(APP_SWIFT_SOURCES) $(SHARED_SOURCES) $(HOSTCORE_SOURCES) \
	$(ACTIVITYCORE_SOURCES) $(ACTIVITY_ATTRIBUTES_SOURCES) $(SESSION_CONTROL_INTENT_SOURCES) $(APP_KEYBOARDCORE_SOURCES)
KEYBOARD_SOURCES = $(KEYBOARD_SWIFT_SOURCES) $(SHARED_SOURCES) $(KEYBOARDCORE_SOURCES)
ACTIVITY_SOURCES = $(ACTIVITY_SWIFT_SOURCES) $(ACTIVITYCORE_SOURCES) $(ACTIVITY_KEYBOARDCORE_SOURCES)

OBJ_DIR = $(BUILD_DIR)/obj
APP_BUNDLE = $(BUILD_DIR)/Sorello.app
APPEX_BUNDLE = $(APP_BUNDLE)/PlugIns/SorelloKeyboard.appex
ACTIVITY_APPEX_BUNDLE = $(APP_BUNDLE)/PlugIns/SorelloActivity.appex
APP_BINARY = $(OBJ_DIR)/Sorello
KEYBOARD_BINARY = $(OBJ_DIR)/SorelloKeyboard
ACTIVITY_BINARY = $(OBJ_DIR)/SorelloActivity
APP_ENTITLEMENTS = $(OBJ_DIR)/Sorello.xcent
KEYBOARD_ENTITLEMENTS = $(OBJ_DIR)/SorelloKeyboard.xcent
ACTIVITY_ENTITLEMENTS = $(OBJ_DIR)/SorelloActivity.xcent
# Swift const values of the intent's source, from each binary's compile, for its Metadata.appintents.
APP_CONST_VALUES = $(OBJ_DIR)/appintents/Sorello.swiftconstvalues
ACTIVITY_CONST_VALUES = $(OBJ_DIR)/appintents/SorelloActivity.swiftconstvalues
APP_SIGNATURE = $(APP_BUNDLE)/_CodeSignature/CodeResources
ICON_CATALOG = $(OBJ_DIR)/Assets.xcassets
IPA = $(BUILD_DIR)/Sorello.ipa
CONFIG_STAMP = $(OBJ_DIR)/configuration
MODEL_STAMP = $(OBJ_DIR)/model-selection
SWIPE_STAMP = $(OBJ_DIR)/swipe-selection
MODEL_INSTALL_KEY = $(OBJ_DIR)/model-installed
# What the app's copy of the model is made from, besides the model itself: the pin it is checked against, the model's
# notices, which ship beside it, and the script that checks and copies it.
MODEL_INPUTS = ../Models/model.lock.json $(wildcard ../Resources/ModelNotices/*) scripts/copy-model.py
HOST_BUILD_DIR ?= build/host
# The shared modules require macOS 26, as the Mac app does.
HOST_TARGET ?= $(shell uname -m)-apple-macosx26.0

# Sorello's shared modules (../ARCHITECTURE.md, section 13), built by SwiftPM from the package as two static
# libraries: the app links SorelloSpeech (SpeechEngine, DictionaryKit, TextRules and DictationCore), the keyboard
# SorelloText (TextRules alone), and the Live Activity neither. Each target triple has a build directory of its own,
# $(PACKAGE_BUILD_DIR)/<triple>, built again whenever the package's manifest or a source of those modules changes, and
# SwiftPM rebuilds only what changed. <triple>.bin-path records where SwiftPM put the libraries and their modules, as
# SwiftPM says (--show-bin-path). The first build of a checkout fetches the package's one dependency, Sparkle, which
# only the Mac app links.
PACKAGE_BUILD_DIR ?= build/package
PACKAGE_SOURCES := ../Package.swift ../Package.resolved \
	$(call swift_sources,../Sources/DictationCore ../Sources/TextRules ../Sources/DictionaryKit ../Sources/SpeechEngine)
SIMULATOR_TARGET = arm64-apple-ios$(DEPLOYMENT_TARGET)-simulator
PACKAGE = $(PACKAGE_BUILD_DIR)/$(TARGET).bin-path
SIMULATOR_PACKAGE = $(PACKAGE_BUILD_DIR)/$(SIMULATOR_TARGET).bin-path
HOST_PACKAGE = $(PACKAGE_BUILD_DIR)/$(HOST_TARGET).bin-path
# $(1): a .bin-path file. Shell words that find the modules of that build.
package_modules = -I "$$(cat "$(1)")"
# $(1): a .bin-path file, $(2): a library of that build. Shell words that find its modules and link the library.
package_library = $(call package_modules,$(1)) -L "$$(cat "$(1)")" -l$(2)

SWIFTC = xcrun --sdk $(SDK) swiftc
# Without -j, swiftc compiles one file at a time. (-enable-batch-mode would save a
# little more, but Swift 6.4 then links temporary objects it never wrote unless
# given an output file map.)
SWIFT_JOBS ?= $(shell sysctl -n hw.activecpu)
SWIFT_PARALLEL_FLAGS = -j$(SWIFT_JOBS)
SWIFT_COMMON_FLAGS = -swift-version 5 -parse-as-library -target $(TARGET) -sdk "$(SDK_PATH)" $(SWIFT_PARALLEL_FLAGS) $(SWIFT_FLAGS)
KEYBOARD_SWIFT_FLAGS = -module-name SorelloKeyboard -application-extension
KEYBOARD_LINK_FLAGS = -Xlinker -e -Xlinker _NSExtensionMain
# A WidgetKit extension. As Xcode links every app extension, the entry point is _NSExtensionMain, which starts the
# @main widget bundle; with the bundle's own main as the entry, the process exits as soon as WidgetKit launches it.
ACTIVITY_SWIFT_FLAGS = -module-name SorelloActivity -application-extension
ACTIVITY_LINK_FLAGS = $(KEYBOARD_LINK_FLAGS)

# App Intents metadata, as Xcode makes it (ARCHITECTURE.md, "Build and targets"). The compile emits the intent
# source's const values through an output file map naming only that file (the other outputs stay temporary), with
# Xcode's protocol list; appintentsmetadataprocessor then writes the bundle's Metadata.appintents.
APPINTENTS_PROTOCOLS = Config/AppIntentsConstProtocols.json
TOOLCHAIN_DIR := $(abspath $(dir $(shell xcrun -f swiftc))/../..)
# $(1): the const values file. Its output file map sits beside it.
const_values_flags = -emit-const-values -output-file-map "$(1).map.json" \
	-Xfrontend -const-gather-protocols-file -Xfrontend "$(abspath $(APPINTENTS_PROTOCOLS))"
# $(1): the const values file.
write_const_values_map = mkdir -p "$(dir $(1))" && rm -f "$(1)" && \
	printf '{"%s": {"const-values": "%s"}}\n' "$(SESSION_CONTROL_INTENT_SOURCES)" "$(abspath $(1))" > "$(1).map.json"
# $(1): module, $(2): bundle identifier, $(3): bundle directory, $(4): binary, $(5): const values file.
appintents_metadata = list="$(5).lists" && printf '%s\n' "$(SESSION_CONTROL_INTENT_SOURCES)" > "$$list.sources" && \
	printf '%s\n' "$(5)" > "$$list.values" && rm -rf "$(3)/Metadata.appintents" && \
	xcrun appintentsmetadataprocessor --toolchain-dir "$(TOOLCHAIN_DIR)" --module-name $(1) --sdk-root "$(SDK_PATH)" \
		--xcode-version "$(XCODE_BUILD)" --platform-family iOS --deployment-target $(DEPLOYMENT_TARGET) \
		--bundle-identifier $(2) --output "$(3)" --target-triple $(TARGET) --binary-file "$(4)" \
		--source-file-list "$$list.sources" --swift-const-vals-list "$$list.values" --compile-time-extraction \
		--deployment-aware-processing --no-app-shortcuts-localization > "$$list.log" 2>&1 && \
	[ -f "$(3)/Metadata.appintents/extract.actionsdata" ] && grep -q '"ToggleFlowSessionIntent"' "$(3)/Metadata.appintents/extract.actionsdata" || \
		{ cat "$$list.log" >&2; echo "No App Intents metadata for $(1)" >&2; exit 1; }

ifeq ($(PLATFORM),simulator)
# The simulator reads entitlements from these sections, as Xcode arranges for
# simulator builds; the ad-hoc signature itself carries none.
embedded_entitlements = -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$(1)" \
	-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __ents_der -Xlinker "$(1).der"
LINKED_APP_ENTITLEMENTS = $(APP_ENTITLEMENTS)
LINKED_KEYBOARD_ENTITLEMENTS = $(KEYBOARD_ENTITLEMENTS)
LINKED_ACTIVITY_ENTITLEMENTS = $(ACTIVITY_ENTITLEMENTS)
SIGNED_APP_ENTITLEMENTS =
SIGNED_KEYBOARD_ENTITLEMENTS =
SIGNED_ACTIVITY_ENTITLEMENTS =
else
embedded_entitlements =
LINKED_APP_ENTITLEMENTS =
LINKED_KEYBOARD_ENTITLEMENTS =
LINKED_ACTIVITY_ENTITLEMENTS =
SIGNED_APP_ENTITLEMENTS = --entitlements "$(APP_ENTITLEMENTS)"
SIGNED_KEYBOARD_ENTITLEMENTS = --entitlements "$(KEYBOARD_ENTITLEMENTS)"
SIGNED_ACTIVITY_ENTITLEMENTS = --entitlements "$(ACTIVITY_ENTITLEMENTS)"
endif

# $(1): template, $(2): output, $(3): bundle identifier. The activity extension's (info_plist_base) has no
# Sorello keys: it reads neither the App Group nor the scheme.
info_plist = $(call info_plist_base,$(1),$(2),$(3)) && \
	plutil -replace SorelloAppGroupIdentifier -string "$(APP_GROUP)" "$(2)" && \
	$(if $(strip $(UNIVERSAL_LINK)),plutil -replace SorelloUniversalLink -string "$(UNIVERSAL_LINK)" "$(2)" &&) \
	plutil -replace SorelloURLScheme -string "$(URL_SCHEME)" "$(2)"
info_plist_base = cp "$(1)" "$(2)" && \
	plutil -replace CFBundleIdentifier -string "$(3)" "$(2)" && \
	plutil -replace CFBundleDisplayName -string "$(DISPLAY_NAME)" "$(2)" && \
	plutil -replace CFBundleSupportedPlatforms -json '["$(SUPPORTED_PLATFORM)"]' "$(2)" && \
	plutil -replace DTPlatformName -string "$(SDK)" "$(2)" && \
	plutil -replace DTPlatformVersion -string "$(SDK_VERSION)" "$(2)" && \
	plutil -replace DTSDKName -string "$(SDK)$(SDK_VERSION)" "$(2)" && \
	plutil -replace DTSDKBuild -string "$(SDK_BUILD)" "$(2)" && \
	plutil -replace DTPlatformBuild -string "$(SDK_BUILD)" "$(2)" && \
	plutil -replace DTXcode -string "$(DT_XCODE)" "$(2)" && \
	plutil -replace DTXcodeBuild -string "$(XCODE_BUILD)" "$(2)" && \
	plutil -replace DTCompiler -string com.apple.compilers.llvm.clang.1_0 "$(2)" && \
	plutil -replace BuildMachineOSBuild -string "$(BUILD_MACHINE_OS_BUILD)" "$(2)" && \
	$(if $(strip $(BUILD_NUMBER)),plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(2)" &&) \
	plutil -replace MinimumOSVersion -string "$(DEPLOYMENT_TARGET)" "$(2)"

.PHONY: all binaries check typecheck test lint check-binaries install-sim run-sim smoke-sim clean configuration model-selection swipe-selection signing-requirements FORCE

all: signing-requirements $(APP_SIGNATURE)

binaries: $(APP_BINARY) $(KEYBOARD_BINARY) $(ACTIVITY_BINARY)

# Rebuild when identifiers, flags, signing inputs or source lists change.
CONFIGURATION = $(CHANNEL)|$(PLATFORM)|$(BUNDLE_ID)|$(APP_GROUP)|$(URL_SCHEME)|$(UNIVERSAL_LINK)|$(DISPLAY_NAME)|$(DEPLOYMENT_TARGET)|$(SDK_PATH)|$(SWIFT_OPTIMIZATION)|$(SWIFT_FLAGS)|$(CODESIGN_IDENTITY)|$(TEAM_ID)|$(APP_PROFILE)|$(KEYBOARD_PROFILE)|$(ACTIVITY_PROFILE)|$(ICON_SOURCE)|$(XCODE_BUILD)|$(SDK_BUILD)|$(BUILD_NUMBER)|$(APP_SOURCES)|$(KEYBOARD_SOURCES)|$(ACTIVITY_SOURCES)
configuration:
	@mkdir -p "$(OBJ_DIR)"
	@printf '%s\n' "$(CONFIGURATION)" > "$(CONFIG_STAMP).tmp"
	@if cmp -s "$(CONFIG_STAMP).tmp" "$(CONFIG_STAMP)"; then rm -f "$(CONFIG_STAMP).tmp"; else mv "$(CONFIG_STAMP).tmp" "$(CONFIG_STAMP)"; fi

$(CONFIG_STAMP): configuration

# Weights stay outside Git and are copied only into the local app bundle. bundle.json lists every file's SHA-256, so
# its hash stands for the whole model.
model-selection:
	@mkdir -p "$(OBJ_DIR)"
	@printf '%s\n' "$(SORELLO_MODEL_DIR)" > "$(MODEL_STAMP).tmp"
ifneq ($(strip $(SORELLO_MODEL_DIR)),)
	@test -f "$(SORELLO_MODEL_DIR)/bundle.json" || { rm -rf "$(MODEL_STAMP).tmp" "$(MODEL_INSTALL_KEY)" "$(APP_BUNDLE)/Model" \
		"$(APP_BUNDLE)/model.lock.json" "$(APP_BUNDLE)/ModelNotices"; echo "SORELLO_MODEL_DIR has no bundle.json." >&2; exit 1; }
	@shasum -a 256 "$(SORELLO_MODEL_DIR)/bundle.json" >> "$(MODEL_STAMP).tmp"
endif
	@if cmp -s "$(MODEL_STAMP).tmp" "$(MODEL_STAMP)"; then rm -f "$(MODEL_STAMP).tmp"; else mv "$(MODEL_STAMP).tmp" "$(MODEL_STAMP)"; fi

$(MODEL_STAMP): model-selection

# The swipe bundle stays outside Git too; bundle.json lists every file's SHA-256,
# so its hash stands for the whole bundle. The stamp has its own recipe, run every
# time, so make sees its new time when the selection changes and repackages.
swipe-selection: $(SWIPE_STAMP)

$(SWIPE_STAMP): FORCE
	@mkdir -p "$(OBJ_DIR)"
	@printf '%s\n' "$(SWIPE_BUNDLE_DIR)" > "$(SWIPE_STAMP).tmp"
ifneq ($(strip $(SWIPE_BUNDLE_DIR)),)
	@test -f "$(SWIPE_BUNDLE_DIR)/bundle.json" || { rm -f "$(SWIPE_STAMP).tmp"; echo "SWIPE_BUNDLE_DIR has no bundle.json." >&2; exit 1; }
	@shasum -a 256 "$(SWIPE_BUNDLE_DIR)/bundle.json" >> "$(SWIPE_STAMP).tmp"
endif
	@if cmp -s "$(SWIPE_STAMP).tmp" "$(SWIPE_STAMP)"; then rm -f "$(SWIPE_STAMP).tmp"; else mv "$(SWIPE_STAMP).tmp" "$(SWIPE_STAMP)"; fi

FORCE:

signing-requirements:
ifeq ($(PLATFORM),device)
	@if [ -z "$(TEAM_ID)" ] || [ -z "$(APP_PROFILE)" ] || [ -z "$(KEYBOARD_PROFILE)" ] || [ -z "$(ACTIVITY_PROFILE)" ] || [ -z "$(CODESIGN_IDENTITY)" ] || [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
		echo "PLATFORM=device needs CODESIGN_IDENTITY, TEAM_ID, APP_PROFILE, KEYBOARD_PROFILE and ACTIVITY_PROFILE (see iOS/README.md)." >&2; \
		echo "Use 'make PLATFORM=device binaries' to compile and link without signing." >&2; exit 1; \
	fi
	@for profile in "$(APP_PROFILE)" "$(KEYBOARD_PROFILE)" "$(ACTIVITY_PROFILE)"; do \
		[ -f "$$profile" ] || { echo "Provisioning profile not found: $$profile" >&2; exit 1; }; \
	done
endif
ifeq ($(CHANNEL),appstore)
	@[ -n "$(strip $(SORELLO_MODEL_DIR))" ] || { echo "CHANNEL=appstore needs SORELLO_MODEL_DIR (the model ships in the app)." >&2; exit 1; }
endif

# The app and the keyboard share the App Group; the activity extension has no capability at all.
$(APP_ENTITLEMENTS) $(KEYBOARD_ENTITLEMENTS): ENTITLED_APP_GROUP = $(APP_GROUP)
$(ACTIVITY_ENTITLEMENTS): ENTITLED_APP_GROUP =
$(APP_ENTITLEMENTS): ENTITLED_BUNDLE_ID = $(BUNDLE_ID)
$(APP_ENTITLEMENTS): ENTITLED_PROFILE = $(APP_PROFILE)
$(APP_ENTITLEMENTS): $(wildcard $(APP_PROFILE))
# Only the app opens the universal link, so only the app claims its domain.
$(APP_ENTITLEMENTS): ENTITLED_DOMAIN = $(if $(strip $(UNIVERSAL_LINK)),applinks:$(UNIVERSAL_LINK_HOST))
$(KEYBOARD_ENTITLEMENTS): ENTITLED_BUNDLE_ID = $(KEYBOARD_BUNDLE_ID)
$(KEYBOARD_ENTITLEMENTS): ENTITLED_PROFILE = $(KEYBOARD_PROFILE)
$(KEYBOARD_ENTITLEMENTS): $(wildcard $(KEYBOARD_PROFILE))
$(KEYBOARD_ENTITLEMENTS): ENTITLED_DOMAIN =
$(ACTIVITY_ENTITLEMENTS): ENTITLED_BUNDLE_ID = $(ACTIVITY_BUNDLE_ID)
$(ACTIVITY_ENTITLEMENTS): ENTITLED_PROFILE = $(ACTIVITY_PROFILE)
$(ACTIVITY_ENTITLEMENTS): $(wildcard $(ACTIVITY_PROFILE))
$(ACTIVITY_ENTITLEMENTS): ENTITLED_DOMAIN =

$(OBJ_DIR)/%.xcent: Config/%.entitlements $(CONFIG_STAMP) Makefile | signing-requirements
	@mkdir -p "$(@D)"
	@cp "$<" "$@.tmp"
	@if [ -n "$(ENTITLED_APP_GROUP)" ]; then \
		/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $(ENTITLED_APP_GROUP)" "$@.tmp"; \
	fi
	@if [ -n "$(ENTITLED_DOMAIN)" ]; then \
		/usr/libexec/PlistBuddy -c "Add :com.apple.developer.associated-domains array" \
			-c "Add :com.apple.developer.associated-domains:0 string $(ENTITLED_DOMAIN)" "$@.tmp"; \
	fi
ifeq ($(PLATFORM),device)
	@# Signed entitlements must be a subset of the provisioning profile's.
	@profile="$@.profile.plist"; trap 'rm -f "$$profile"' EXIT; \
	security cms -D -i "$(ENTITLED_PROFILE)" > "$$profile" 2>/dev/null || { echo "Cannot decode $(ENTITLED_PROFILE)" >&2; exit 1; }; \
	expected="$(TEAM_ID).$(ENTITLED_BUNDLE_ID)"; \
	actual=$$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "$$profile" 2>/dev/null); \
	[ "$$actual" = "$$expected" ] || { echo "$(ENTITLED_PROFILE) is for '$$actual', expected '$$expected'." >&2; exit 1; }; \
	if [ -n "$(ENTITLED_APP_GROUP)" ]; then \
		/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.security.application-groups" "$$profile" 2>/dev/null | tr -d ' ' | grep -Fqx "$(ENTITLED_APP_GROUP)" || \
			{ echo "$(ENTITLED_PROFILE) does not grant App Group $(ENTITLED_APP_GROUP)." >&2; exit 1; }; \
	fi; \
	if [ -n "$(ENTITLED_DOMAIN)" ]; then \
		/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.associated-domains" "$$profile" 2>/dev/null | tr -d ' ' | \
			grep -Fqx -e "$(ENTITLED_DOMAIN)" -e '*' || \
			{ echo "$(ENTITLED_PROFILE) does not grant the Associated Domains capability for $(ENTITLED_DOMAIN): enable Associated Domains on the App ID $(ENTITLED_BUNDLE_ID) and regenerate the profile, or build with UNIVERSAL_LINK= (dev only)." >&2; exit 1; }; \
	fi; \
	debuggable=$$(/usr/libexec/PlistBuddy -c "Print :Entitlements:get-task-allow" "$$profile" 2>/dev/null || echo false); \
	/usr/libexec/PlistBuddy -c "Add :application-identifier string $$expected" \
		-c "Add :com.apple.developer.team-identifier string $(TEAM_ID)" \
		-c "Add :get-task-allow bool $$debuggable" "$@.tmp"; \
	if [ "$$(/usr/libexec/PlistBuddy -c "Print :Entitlements:beta-reports-active" "$$profile" 2>/dev/null)" = true ]; then \
		/usr/libexec/PlistBuddy -c "Add :beta-reports-active bool true" "$@.tmp"; \
	fi
ifeq ($(CHANNEL),appstore)
	@# An App Store profile lists no devices, is not an enterprise profile, never
	@# allows debugging, and allows TestFlight (beta-reports-active).
	@profile="$@.profile.plist"; trap 'rm -f "$$profile"' EXIT; \
	security cms -D -i "$(ENTITLED_PROFILE)" > "$$profile" 2>/dev/null; \
	if /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$$profile" >/dev/null 2>&1 || \
		[ "$$(/usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$$profile" 2>/dev/null)" = true ] || \
		[ "$$(/usr/libexec/PlistBuddy -c "Print :Entitlements:get-task-allow" "$$profile" 2>/dev/null)" = true ] || \
		[ "$$(/usr/libexec/PlistBuddy -c "Print :Entitlements:beta-reports-active" "$$profile" 2>/dev/null)" != true ]; then \
		echo "$(ENTITLED_PROFILE) is not an App Store distribution profile." >&2; exit 1; \
	fi
endif
endif
	@mv "$@.tmp" "$@"
ifeq ($(PLATFORM),simulator)
	@derq query -f xml -i "$@" -o "$@.der" --raw
endif

# The SDK a triple builds against.
package_sdk = case "$(1)" in *-simulator) sdk=iphonesimulator ;; *-macosx*) sdk=macosx ;; *) sdk=iphoneos ;; esac
# What a triple's libraries are built from besides the sources' contents: the toolchain, the SDK and the list of
# sources, so a different Xcode or SDK, or a source added or deleted, builds them again. Rewritten only when it changes.
$(PACKAGE_BUILD_DIR)/%.inputs: FORCE
	@set -e; $(call package_sdk,$*); mkdir -p "$(@D)"; \
	printf '%s\n' "$(TOOLCHAIN_DIR)|$(XCODE_BUILD)|$$(xcrun --sdk $$sdk --show-sdk-path)|$$(xcrun --sdk $$sdk --show-sdk-build-version)|$(PACKAGE_SOURCES)" > "$@.$$$$"; \
	if cmp -s "$@.$$$$" "$@"; then rm -f "$@.$$$$"; else mv "$@.$$$$" "$@"; fi

# Both are kept between runs; neither is an intermediate file make may delete.
.PRECIOUS: $(PACKAGE_BUILD_DIR)/%.inputs $(PACKAGE_BUILD_DIR)/%.bin-path

# $*: the target triple; the SDK follows from it. Both libraries, then where SwiftPM put them.
$(PACKAGE_BUILD_DIR)/%.bin-path: $(PACKAGE_BUILD_DIR)/%.inputs $(PACKAGE_SOURCES) Makefile
	@set -e; $(call package_sdk,$*); \
	sdk_path=$$(xcrun --sdk $$sdk --show-sdk-path); scratch="$(abspath $(PACKAGE_BUILD_DIR))/$*"; \
	package() { swift build --package-path .. -c release --triple "$*" --sdk "$$sdk_path" --scratch-path "$$scratch" "$$@"; }; \
	echo "Building SorelloSpeech and SorelloText for $*"; \
	package --product SorelloSpeech; package --product SorelloText; \
	mkdir -p "$(@D)"; package --product SorelloSpeech --show-bin-path > "$@.$$$$"; mv "$@.$$$$" "$@"

$(APP_BINARY): $(APP_SOURCES) $(PACKAGE) $(CONFIG_STAMP) $(LINKED_APP_ENTITLEMENTS) $(APPINTENTS_PROTOCOLS) Makefile
	@mkdir -p "$(@D)"
	@$(call write_const_values_map,$(APP_CONST_VALUES))
	$(SWIFTC) $(SWIFT_COMMON_FLAGS) $(SWIFT_OPTIMIZATION) -module-name Sorello $(call const_values_flags,$(APP_CONST_VALUES)) \
		$(call package_library,$(PACKAGE),SorelloSpeech) \
		$(call embedded_entitlements,$(APP_ENTITLEMENTS)) -o "$@" $(APP_SOURCES)

$(KEYBOARD_BINARY): $(KEYBOARD_SOURCES) $(PACKAGE) $(CONFIG_STAMP) $(LINKED_KEYBOARD_ENTITLEMENTS) Makefile
	@mkdir -p "$(@D)"
	$(SWIFTC) $(SWIFT_COMMON_FLAGS) $(SWIFT_OPTIMIZATION) $(KEYBOARD_SWIFT_FLAGS) $(KEYBOARD_LINK_FLAGS) \
		$(call package_library,$(PACKAGE),SorelloText) \
		$(call embedded_entitlements,$(KEYBOARD_ENTITLEMENTS)) -o "$@" $(KEYBOARD_SOURCES)

$(ACTIVITY_BINARY): $(ACTIVITY_SOURCES) $(CONFIG_STAMP) $(LINKED_ACTIVITY_ENTITLEMENTS) $(APPINTENTS_PROTOCOLS) Makefile
	@mkdir -p "$(@D)"
	@$(call write_const_values_map,$(ACTIVITY_CONST_VALUES))
	$(SWIFTC) $(SWIFT_COMMON_FLAGS) $(SWIFT_OPTIMIZATION) $(ACTIVITY_SWIFT_FLAGS) $(ACTIVITY_LINK_FLAGS) \
		$(call const_values_flags,$(ACTIVITY_CONST_VALUES)) \
		$(call embedded_entitlements,$(ACTIVITY_ENTITLEMENTS)) -o "$@" $(ACTIVITY_SOURCES)

$(APP_SIGNATURE): $(APP_BINARY) $(KEYBOARD_BINARY) $(ACTIVITY_BINARY) $(APP_ENTITLEMENTS) $(KEYBOARD_ENTITLEMENTS) \
		$(ACTIVITY_ENTITLEMENTS) Makefile Config/Sorello-Info.plist Config/SorelloKeyboard-Info.plist \
		Config/SorelloActivity-Info.plist $(ICON_SOURCE) $(MODEL_STAMP) Config/Sorello-PrivacyInfo.xcprivacy \
		Config/SorelloKeyboard-PrivacyInfo.xcprivacy Config/SorelloActivity-PrivacyInfo.xcprivacy \
		$(MODEL_INPUTS) \
		$(SWIPE_STAMP) $(wildcard Resources/Swipe/LICENSE-*) $(APP_FONTS)
	@rm -rf "$(APPEX_BUNDLE)" "$(ACTIVITY_APPEX_BUNDLE)" "$(APP_BUNDLE)/_CodeSignature" "$(APP_BUNDLE)/embedded.mobileprovision" "$(APP_BUNDLE)/Fonts"
	@mkdir -p "$(APPEX_BUNDLE)" "$(ACTIVITY_APPEX_BUNDLE)"
	@cp "$(APP_BINARY)" "$(APP_BUNDLE)/Sorello"
	@cp "$(KEYBOARD_BINARY)" "$(APPEX_BUNDLE)/SorelloKeyboard"
	@cp "$(ACTIVITY_BINARY)" "$(ACTIVITY_APPEX_BUNDLE)/SorelloActivity"
	@$(call appintents_metadata,Sorello,$(BUNDLE_ID),$(APP_BUNDLE),$(APP_BINARY),$(APP_CONST_VALUES))
	@$(call appintents_metadata,SorelloActivity,$(ACTIVITY_BUNDLE_ID),$(ACTIVITY_APPEX_BUNDLE),$(ACTIVITY_BINARY),$(ACTIVITY_CONST_VALUES))
	@$(call info_plist,Config/Sorello-Info.plist,$(APP_BUNDLE)/Info.plist,$(BUNDLE_ID))
	@plutil -replace CFBundleURLTypes.0.CFBundleURLName -string "$(BUNDLE_ID)" "$(APP_BUNDLE)/Info.plist"
	@plutil -replace CFBundleURLTypes.0.CFBundleURLSchemes -json '["$(URL_SCHEME)"]' "$(APP_BUNDLE)/Info.plist"
	@$(call info_plist,Config/SorelloKeyboard-Info.plist,$(APPEX_BUNDLE)/Info.plist,$(KEYBOARD_BUNDLE_ID))
	@$(call info_plist_base,Config/SorelloActivity-Info.plist,$(ACTIVITY_APPEX_BUNDLE)/Info.plist,$(ACTIVITY_BUNDLE_ID))
	@! grep -l '\$$(' "$(APP_BUNDLE)/Info.plist" "$(APPEX_BUNDLE)/Info.plist" "$(ACTIVITY_APPEX_BUNDLE)/Info.plist" || { echo "Unexpanded Info.plist placeholder" >&2; exit 1; }
	@printf 'APPL????' > "$(APP_BUNDLE)/PkgInfo"
	@cp Config/Sorello-PrivacyInfo.xcprivacy "$(APP_BUNDLE)/PrivacyInfo.xcprivacy"
	@cp Config/SorelloKeyboard-PrivacyInfo.xcprivacy "$(APPEX_BUNDLE)/PrivacyInfo.xcprivacy"
	@cp Config/SorelloActivity-PrivacyInfo.xcprivacy "$(ACTIVITY_APPEX_BUNDLE)/PrivacyInfo.xcprivacy"
	@mkdir -p "$(APP_BUNDLE)/Fonts" && cp $(APP_FONTS) "$(APP_BUNDLE)/Fonts/"
	@# The icon source is a full-bleed square (Resources/ICON.md); iOS applies its
	@# own mask. The App Store rejects an icon with an alpha channel, so it is
	@# flattened (through JPEG at the best quality) before scaling to the single
	@# 1024-pixel size.
	@rm -rf "$(ICON_CATALOG)" "$(APP_BUNDLE)"/AppIcon*.png && mkdir -p "$(ICON_CATALOG)/AppIcon.appiconset"
	@sips -s format jpeg -s formatOptions best "$(ICON_SOURCE)" --out "$(OBJ_DIR)/AppIcon-flat.jpg" >/dev/null
	@sips -s format png -z 1024 1024 "$(OBJ_DIR)/AppIcon-flat.jpg" --out "$(ICON_CATALOG)/AppIcon.appiconset/AppIcon-1024.png" >/dev/null
	@[ "$$(sips -g hasAlpha "$(ICON_CATALOG)/AppIcon.appiconset/AppIcon-1024.png" | awk '/hasAlpha/ { print $$2 }')" = no ] || \
		{ echo "The App Store icon still has an alpha channel." >&2; exit 1; }
	@printf '%s\n' '{"info":{"author":"xcode","version":1}}' > "$(ICON_CATALOG)/Contents.json"
	@printf '%s\n' '{"images":[{"filename":"AppIcon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}' \
		> "$(ICON_CATALOG)/AppIcon.appiconset/Contents.json"
	@xcrun actool --compile "$(APP_BUNDLE)" --platform $(SDK) --minimum-deployment-target $(DEPLOYMENT_TARGET) \
		--target-device iphone --app-icon AppIcon --output-partial-info-plist "$(OBJ_DIR)/assets-Info.plist" \
		--errors --warnings --output-format human-readable-text "$(ICON_CATALOG)" > "$(OBJ_DIR)/actool.log" 2>&1 || \
		{ cat "$(OBJ_DIR)/actool.log" >&2; exit 1; }
	@/usr/libexec/PlistBuddy -c "Merge $(OBJ_DIR)/assets-Info.plist" "$(APP_BUNDLE)/Info.plist" >/dev/null
ifneq ($(strip $(SORELLO_MODEL_DIR)),)
	@{ cat "$(MODEL_STAMP)"; printf '%s\n' "$(DEPLOYMENT_TARGET)"; shasum -a 256 $(MODEL_INPUTS); } > "$(MODEL_INSTALL_KEY).tmp"
	@# Copying 138 MB is slow, so keep the installed copy while its inputs are unchanged.
	@if [ -f "$(APP_BUNDLE)/Model/bundle.json" ] && cmp -s "$(MODEL_INSTALL_KEY).tmp" "$(MODEL_INSTALL_KEY)"; then \
		echo "Reusing installed model files"; \
	else \
		rm -f "$(MODEL_INSTALL_KEY)" && \
		$(PYTHON) scripts/copy-model.py ../Models/model.lock.json "$(SORELLO_MODEL_DIR)" ../Resources/ModelNotices \
			"$(APP_BUNDLE)" $(DEPLOYMENT_TARGET) && \
		cp "$(MODEL_INSTALL_KEY).tmp" "$(MODEL_INSTALL_KEY)"; \
	fi
	@rm -f "$(MODEL_INSTALL_KEY).tmp"
else
	@rm -rf "$(APP_BUNDLE)/Model" "$(APP_BUNDLE)/model.lock.json" "$(APP_BUNDLE)/ModelNotices" "$(MODEL_INSTALL_KEY)"
endif
ifneq ($(strip $(SWIPE_BUNDLE_DIR)),)
	@# Swipe typing: exactly the files bundle.json lists, each checked against its
	@# SHA-256 as copied, then bundle.json and the licenses. Without it the
	@# keyboard has no Swipe directory and no swipe typing.
	@set -e; src="$(SWIPE_BUNDLE_DIR)"; dest="$(APPEX_BUNDLE)/Swipe"; list="$(OBJ_DIR)/swipe-files"; tab=$$(printf '\t'); \
	fail() { echo "SWIPE_BUNDLE_DIR: $$1" >&2; rm -rf "$$dest" "$$list"; exit 1; }; \
	[ "$$(plutil -extract format raw -o - "$$src/bundle.json" 2>/dev/null)" = 1 ] || fail "bundle.json is not format 1"; \
	for key in beam top_k length_power freq_weight length_bonus; do \
		plutil -extract "decode.$$key" raw -o - "$$src/bundle.json" >/dev/null 2>&1 || fail "bundle.json has no decode.$$key"; \
	done; \
	plutil -extract files xml1 -o - "$$src/bundle.json" 2>/dev/null \
		| sed -n -E 's,^[[:space:]]*<(key|string)>(.*)</(key|string)>[[:space:]]*$$,\2,p' | paste - - > "$$list" || fail "bundle.json has no files"; \
	cut -f1 "$$list" | grep -qx 'lexicon\.bin' || fail "bundle.json does not list lexicon.bin"; \
	cut -f1 "$$list" | grep -q '^SwipeEncoder\.mlmodelc/' || fail "bundle.json does not list SwipeEncoder.mlmodelc"; \
	rm -rf "$$dest"; mkdir -p "$$dest"; \
	while IFS="$$tab" read -r path digest; do \
		case "$$path" in ""|/*|../*|*/../*|*/..|..|bundle.json|*"&"*) fail "bundle.json lists an invalid path" ;; esac; \
		case "$$digest" in *[!0-9a-f]*|"") fail "bundle.json has an invalid SHA-256 for $$path" ;; esac; \
		[ $${#digest} -eq 64 ] || fail "bundle.json has an invalid SHA-256 for $$path"; \
		[ -f "$$src/$$path" ] || fail "$$path is missing"; \
		mkdir -p "$$(dirname "$$dest/$$path")"; \
		cp -X "$$src/$$path" "$$dest/$$path"; \
		[ "$$(shasum -a 256 "$$dest/$$path" | awk '{ print $$1 }')" = "$$digest" ] || fail "$$path does not match its SHA-256 in bundle.json"; \
	done < "$$list"; \
	cp -X "$$src/bundle.json" Resources/Swipe/LICENSE-* "$$dest/"; \
	count=$$(wc -l < "$$list" | tr -d ' '); rm -f "$$list"; \
	echo "Copied the swipe bundle ($$count files verified)"
endif
ifeq ($(PLATFORM),device)
	@cp "$(APP_PROFILE)" "$(APP_BUNDLE)/embedded.mobileprovision"
	@cp "$(KEYBOARD_PROFILE)" "$(APPEX_BUNDLE)/embedded.mobileprovision"
	@cp "$(ACTIVITY_PROFILE)" "$(ACTIVITY_APPEX_BUNDLE)/embedded.mobileprovision"
endif
	@# The extensions are sealed inside the app, so they must be signed first.
	@codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_KEYCHAIN_FLAG) $(SIGNED_KEYBOARD_ENTITLEMENTS) --timestamp=none --generate-entitlement-der "$(APPEX_BUNDLE)"
	@codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_KEYCHAIN_FLAG) $(SIGNED_ACTIVITY_ENTITLEMENTS) --timestamp=none --generate-entitlement-der "$(ACTIVITY_APPEX_BUNDLE)"
	@codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_KEYCHAIN_FLAG) $(SIGNED_APP_ENTITLEMENTS) --timestamp=none --generate-entitlement-der "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

.PHONY: ipa appstore-check appstore-validate appstore-upload

# The upload package: exactly the signed app under Payload/.
ipa: all
	@rm -rf "$(OBJ_DIR)/ipa" "$(IPA)" && mkdir -p "$(OBJ_DIR)/ipa/Payload"
	@ditto "$(APP_BUNDLE)" "$(OBJ_DIR)/ipa/Payload/Sorello.app"
	@# Made absolute in the shell, where a path with spaces stays one word.
	@ipa=$(call shell_quote,$(IPA)); case "$$ipa" in /*) ;; *) ipa="$$PWD/$$ipa" ;; esac; \
	mkdir -p "$$(dirname "$$ipa")" && cd "$(OBJ_DIR)/ipa" && zip -qry -X "$$ipa" Payload
	@rm -rf "$(OBJ_DIR)/ipa"
	@echo "Packaged $(IPA)"

# What App Store Connect needs, checked locally from the built app and .ipa
# (scripts/check-appstore-bundle.sh); it never contacts Apple. Asked for with
# ipa, it waits for the package, also under -j.
appstore-check: $(filter ipa,$(MAKECMDGOALS))
	@sh scripts/check-appstore-bundle.sh --app "$(APP_BUNDLE)" --ipa "$(IPA)" --bundle-id "$(BUNDLE_ID)" \
		--app-group "$(APP_GROUP)" --url-scheme "$(URL_SCHEME)" --universal-link "$(UNIVERSAL_LINK)" \
		--display-name "$(DISPLAY_NAME)" --team-id "$(TEAM_ID)" --pin ../Models/model.lock.json \
		--model-notices ../Resources/ModelNotices

# Apple's own checks, then the upload, with an App Store Connect API key
# (ASC_KEY_ID, ASC_ISSUER_ID; the .p8 in ~/.appstoreconnect/private_keys). Both
# send the .ipa to Apple, so neither runs as part of any other target.
appstore-validate appstore-upload: appstore-check
	@[ -n "$(ASC_KEY_ID)" ] && [ -n "$(ASC_ISSUER_ID)" ] || { echo "$@ needs ASC_KEY_ID and ASC_ISSUER_ID." >&2; exit 1; }
	xcrun altool $(if $(filter appstore-upload,$@),--upload-package,--validate-app) "$(IPA)" -t ios \
		--api-key "$(ASC_KEY_ID)" --api-issuer "$(ASC_ISSUER_ID)"

check: typecheck test lint check-binaries

# Always against the simulator SDK, independent of PLATFORM. The self-test
# variant is checked too, so it cannot rot outside its builds.
typecheck: $(SIMULATOR_PACKAGE)
	@set -e; sdk=$$(xcrun --sdk iphonesimulator --show-sdk-path); \
	flags="-typecheck -warnings-as-errors -swift-version 5 -parse-as-library -target $(SIMULATOR_TARGET) -sdk $$sdk $(SWIFT_PARALLEL_FLAGS) $(SWIFT_FLAGS) $(call package_modules,$(SIMULATOR_PACKAGE))"; \
	echo "Type-checking the app"; \
	xcrun --sdk iphonesimulator swiftc $$flags -module-name Sorello $(APP_SOURCES); \
	echo "Type-checking the app (self-test variant)"; \
	xcrun --sdk iphonesimulator swiftc $$flags -D SORELLO_SELFTEST -module-name Sorello $(APP_SOURCES); \
	echo "Type-checking the keyboard"; \
	xcrun --sdk iphonesimulator swiftc $$flags $(KEYBOARD_SWIFT_FLAGS) $(KEYBOARD_SOURCES); \
	echo "Type-checking the Live Activity"; \
	xcrun --sdk iphonesimulator swiftc $$flags $(ACTIVITY_SWIFT_FLAGS) $(ACTIVITY_SOURCES)

# Shared, HostCore, ActivityCore and KeyboardCore are Foundation-only, and so are the shared modules, so their tests run
# on the Mac, against the Mac's build of SorelloSpeech.
test: $(HOST_PACKAGE)
ifeq ($(strip $(TEST_SOURCES)),)
	@echo "No iOS host tests yet; skipping."
else
	@mkdir -p "$(HOST_BUILD_DIR)"
	xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -warnings-as-errors $(SWIFT_PARALLEL_FLAGS) \
		-sdk "$$(xcrun --sdk macosx --show-sdk-path)" -target $(HOST_TARGET) -module-name SorelloiOSTests \
		$(call package_library,$(HOST_PACKAGE),SorelloSpeech) \
		-o "$(HOST_BUILD_DIR)/SorelloiOSTests" $(SHARED_SOURCES) $(HOSTCORE_SOURCES) $(ACTIVITYCORE_SOURCES) $(KEYBOARDCORE_SOURCES) $(KEYBOARD_TEST_SOURCES) $(TEST_SOURCES)
	@"$(HOST_BUILD_DIR)/SorelloiOSTests"
endif

lint:
	plutil -lint Config/*.plist Config/*.entitlements Config/*.xcprivacy
	@for script in scripts/*.sh; do sh -n "$$script" || exit 1; done

# The three executables, built for the simulator, name no networking API, and the keyboard and the Live Activity hold
# nothing of the shared modules they must not reach (scripts/check-binaries.sh).
CHECK_BUILD_DIR = build/simulator
check-binaries:
	@$(MAKE) --no-print-directory binaries PLATFORM=simulator CHANNEL=dev BUILD_DIR="$(CHECK_BUILD_DIR)"
	@sh scripts/check-binaries.sh "$(CHECK_BUILD_DIR)/obj/Sorello" "$(CHECK_BUILD_DIR)/obj/SorelloKeyboard" \
		"$(CHECK_BUILD_DIR)/obj/SorelloActivity"

SIM_DEVICE ?= Sorello-Smoke
SIM_DEVICE_TYPE ?= iPhone 17 Pro
SIM_RUNTIME ?=
# Shell fragment: sets udid for SIM_DEVICE, creating the device on first use
# with SIM_RUNTIME or the newest installed iOS runtime.
SIM_RESOLVE = udid=$$(xcrun simctl list devices available | grep -F "    $(SIM_DEVICE) (" | head -n 1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'); \
	if [ -z "$$udid" ]; then \
		runtime="$(SIM_RUNTIME)"; \
		[ -n "$$runtime" ] || runtime=$$(xcrun simctl list runtimes available | sed -n -E 's/^iOS .* - (com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+)$$/\1/p' | tail -n 1); \
		echo "Creating simulator $(SIM_DEVICE) ($(SIM_DEVICE_TYPE), $$runtime)"; \
		udid=$$(xcrun simctl create "$(SIM_DEVICE)" "$(SIM_DEVICE_TYPE)" "$$runtime"); \
	fi
# Shell fragment: boots udid if needed; booted_here=1 when this run booted it.
SIM_BOOT = booted_here=0; \
	if ! xcrun simctl list devices | grep -F "($$udid) (Booted)" >/dev/null; then booted_here=1; xcrun simctl boot "$$udid"; fi; \
	xcrun simctl bootstatus "$$udid" >/dev/null

install-sim: all
	@set -e; $(SIM_RESOLVE); $(SIM_BOOT); \
	xcrun simctl install "$$udid" "$(APP_BUNDLE)"; \
	echo "Installed $(APP_BUNDLE) on $(SIM_DEVICE)"

run-sim: install-sim
	@set -e; $(SIM_RESOLVE); \
	open -a Simulator --args -CurrentDeviceUDID "$$udid"; \
	xcrun simctl launch --terminate-running-process "$$udid" "$(BUNDLE_ID)"

SMOKE_BUILD_DIR ?= build/smoke-simulator
SMOKE_PHRASE ?= The blue lantern is beside the green notebook.
SMOKE_COMPUTE ?= cpuAndNeuralEngine
SMOKE_TIMEOUT ?= 900
SMOKE_LOG = $(SMOKE_BUILD_DIR)/obj/selftest.log

# Transcribes invented speech from `say` inside the self-test build. The app
# prints only a pass/fail line with timings, never the transcript.
smoke-sim:
	@[ -n "$(strip $(SORELLO_MODEL_DIR))" ] || { echo "smoke-sim needs SORELLO_MODEL_DIR (a copy of the model)." >&2; exit 1; }
	@$(MAKE) --no-print-directory all PLATFORM=simulator BUILD_DIR="$(SMOKE_BUILD_DIR)" SWIFT_FLAGS="$(SWIFT_FLAGS) -D SORELLO_SELFTEST"
	@set -e; $(SIM_RESOLVE); $(SIM_BOOT); \
	trap '[ "$$booted_here" = 1 ] && xcrun simctl shutdown "$$udid"' EXIT; \
	xcrun simctl install "$$udid" "$(SMOKE_BUILD_DIR)/Sorello.app"; \
	say -o "$(SMOKE_BUILD_DIR)/obj/selftest.wav" --data-format=LEI16@16000 "$(SMOKE_PHRASE)"; \
	container=$$(xcrun simctl get_app_container "$$udid" "$(BUNDLE_ID)" data); \
	mkdir -p "$$container/tmp"; \
	mv "$(SMOKE_BUILD_DIR)/obj/selftest.wav" "$$container/tmp/sorello-selftest.wav"; \
	( trap 'kill $$sleeper 2>/dev/null; exit 0' TERM; sleep $(SMOKE_TIMEOUT) & sleeper=$$!; wait $$sleeper; \
		xcrun simctl terminate "$$udid" "$(BUNDLE_ID)" ) >/dev/null 2>&1 & watchdog=$$!; \
	echo "Running the self-test on $(SIM_DEVICE) (compute: $(SMOKE_COMPUTE))"; \
	SIMCTL_CHILD_SORELLO_SELFTEST_AUDIO=tmp/sorello-selftest.wav \
	SIMCTL_CHILD_SORELLO_SELFTEST_EXPECTED="$(SMOKE_PHRASE)" \
	SIMCTL_CHILD_SORELLO_SELFTEST_COMPUTE="$(SMOKE_COMPUTE)" \
		xcrun simctl launch --console-pty --terminate-running-process "$$udid" "$(BUNDLE_ID)" > "$(SMOKE_LOG)" 2>&1 || true; \
	kill $$watchdog 2>/dev/null || true; \
	rm -f "$$container/tmp/sorello-selftest.wav"; \
	result=$$(grep -a '^Sorello self-test:' "$(SMOKE_LOG)" | tail -n 1 | tr -d '\r'); \
	case "$$result" in \
		*"result=pass"*) echo "$$result"; rm -f "$(SMOKE_LOG)" ;; \
		"") echo "No self-test result; see $(SMOKE_LOG)" >&2; exit 1 ;; \
		*) echo "$$result" >&2; echo "See $(SMOKE_LOG)" >&2; exit 1 ;; \
	esac

.PHONY: install-device smoke-device

# A name or identifier from `xcrun devicectl list devices`.
DEVICE ?=
SMOKE_DEVICE_BUILD_DIR ?= build/smoke-device
SMOKE_DEVICE_LOG = $(SMOKE_DEVICE_BUILD_DIR)/obj/selftest.log
# 0 reruns the self-test build already on DEVICE without building or reinstalling it,
# so a second run shows whether Core ML kept its on-device specialization (a warm run).
SMOKE_DEVICE_INSTALL ?= 1
# Shell fragment: fails unless DEVICE is set, reachable and unlocked.
DEVICE_UNLOCKED = [ -n "$(DEVICE)" ] || { echo "Set DEVICE to a name or identifier from 'xcrun devicectl list devices'." >&2; exit 1; }; \
	lock_json=$$(mktemp); \
	xcrun devicectl device info lockState --device "$(DEVICE)" --quiet --json-output "$$lock_json" >/dev/null 2>&1 || \
		{ rm -f "$$lock_json"; echo "Cannot reach $(DEVICE); see 'xcrun devicectl list devices'." >&2; exit 1; }; \
	locked=$$(plutil -extract result.passcodeRequired raw -o - "$$lock_json" 2>/dev/null || echo unknown); rm -f "$$lock_json"; \
	[ "$$locked" = false ] || { echo "Unlock $(DEVICE) and keep it awake until the run finishes." >&2; exit 1; }

# Installs the signed build on DEVICE without launching it (PLATFORM=device).
install-device: all
	@[ -n "$(DEVICE)" ] || { echo "install-device needs DEVICE, a name or identifier from 'xcrun devicectl list devices'." >&2; exit 1; }
	xcrun devicectl device install app --device "$(DEVICE)" "$(APP_BUNDLE)"

# smoke-sim on a device. Builds and signs the self-test variant (it needs the device signing
# variables), replaces the BUNDLE_ID install on DEVICE with it, copies invented `say` speech
# into the app's data container and launches the app with the self-test environment. Prints
# only the content-free result line. The phone must stay unlocked. devicectl cannot delete
# files, so the recording is overwritten with an empty file afterwards.
smoke-device:
	@[ -n "$(DEVICE)" ] || { echo "smoke-device needs DEVICE, a name or identifier from 'xcrun devicectl list devices'." >&2; exit 1; }
ifneq ($(SMOKE_DEVICE_INSTALL),0)
	@[ -n "$(strip $(SORELLO_MODEL_DIR))" ] || { echo "smoke-device needs SORELLO_MODEL_DIR (a copy of the model)." >&2; exit 1; }
	@$(MAKE) --no-print-directory all PLATFORM=device BUILD_DIR="$(SMOKE_DEVICE_BUILD_DIR)" SWIFT_FLAGS="$(SWIFT_FLAGS) -D SORELLO_SELFTEST"
endif
	@set -e; $(DEVICE_UNLOCKED); obj="$(SMOKE_DEVICE_BUILD_DIR)/obj"; mkdir -p "$$obj"; \
	if [ "$(SMOKE_DEVICE_INSTALL)" != 0 ]; then \
		xcrun devicectl device install app --quiet --device "$(DEVICE)" "$(SMOKE_DEVICE_BUILD_DIR)/Sorello.app"; \
	fi; \
	copy_audio() { xcrun devicectl device copy to --quiet --device "$(DEVICE)" --domain-type appDataContainer \
		--domain-identifier "$(BUNDLE_ID)" --source "$$1" --destination tmp/sorello-selftest.wav; }; \
	say -o "$$obj/selftest.wav" --data-format=LEI16@16000 "$(SMOKE_PHRASE)"; : > "$$obj/empty.wav"; \
	trap 'copy_audio "$$obj/empty.wav" >/dev/null 2>&1 || true; rm -f "$$obj/selftest.wav" "$$obj/empty.wav"' EXIT; \
	copy_audio "$$obj/selftest.wav"; \
	echo "Running the self-test on $(DEVICE) (compute: $(SMOKE_COMPUTE))"; \
	DEVICECTL_CHILD_SORELLO_SELFTEST_AUDIO=tmp/sorello-selftest.wav \
	DEVICECTL_CHILD_SORELLO_SELFTEST_EXPECTED="$(SMOKE_PHRASE)" \
	DEVICECTL_CHILD_SORELLO_SELFTEST_COMPUTE="$(SMOKE_COMPUTE)" \
		xcrun devicectl device process launch --device "$(DEVICE)" --console --terminate-existing \
		--timeout $(SMOKE_TIMEOUT) "$(BUNDLE_ID)" > "$(SMOKE_DEVICE_LOG)" 2>&1 || true; \
	result=$$(LC_ALL=C sed -n -E 's/.*(Sorello self-test: result=)/\1/p' "$(SMOKE_DEVICE_LOG)" | tail -n 1 | tr -d '\r'); \
	case "$$result" in \
		*"result=pass"*) echo "$$result"; rm -f "$(SMOKE_DEVICE_LOG)" ;; \
		"") echo "No self-test result; see $(SMOKE_DEVICE_LOG)" >&2; exit 1 ;; \
		*) echo "$$result" >&2; echo "See $(SMOKE_DEVICE_LOG)" >&2; exit 1 ;; \
	esac

.PHONY: e2e-sim e2e-sim-probe e2e-sim-scenarios

E2E_BUILD_DIR ?= build/e2e-simulator
E2E_SIM_DEVICE ?= Sorello-E2E
E2E_PHRASE ?= $(SMOKE_PHRASE)
E2E_AUDIO = tmp/sorello-synthetic-mic.wav
# The App Group's dictation directory (SharedDictationStore), whose name is kept from the app's first name.
E2E_SHARED_DIR = Library/Caches/LocalFlowDictation
E2E_LOG = $(E2E_BUILD_DIR)/obj/e2e-app.log
# Launch options of the self-test build (see App/SelfTest.swift).
E2E_SKIP_ONBOARDING ?=
E2E_SCREEN ?=
E2E_START_SESSION ?=
# bluetooth or none: the route the synthetic microphone reports; empty reports none.
E2E_HEADPHONES ?=
# e2e-sim-probe: seconds between recording and finish, the completion timeout,
# whether to send the app to the background while it records, and whether to
# also open <scheme>://dictate (the simulator asks "Open in …?", which needs a tap).
# E2E_FROM_BACKGROUND=1 needs a running session: Sorello goes to the background
# first and the request is admitted there, as for every dictation after the first.
E2E_SPEAK_SECONDS ?= 4
E2E_TIMEOUT ?= 600
E2E_BACKGROUND ?=
E2E_OPEN_URL ?=
E2E_FROM_BACKGROUND ?=
E2E_KEEP_PRESENCE = $(strip $(E2E_BACKGROUND)$(E2E_FROM_BACKGROUND))

# Installs the self-test variant on a dedicated simulator with the synthetic
# microphone (`say` speech, fed at real-time pace when a dictation starts) and
# leaves it running for a GUI or scripted end-to-end test. It does not open
# Simulator.app, and the Mac microphone is never used.
# simctl needs an absolute log path: an absolute E2E_BUILD_DIR is used as
# given, a relative one is resolved against the iOS directory.
e2e-sim: SIM_DEVICE = $(E2E_SIM_DEVICE)
e2e-sim:
	@[ -n "$(strip $(SORELLO_MODEL_DIR))" ] || { echo "e2e-sim needs SORELLO_MODEL_DIR (a copy of the model)." >&2; exit 1; }
	@$(MAKE) --no-print-directory all PLATFORM=simulator BUILD_DIR="$(E2E_BUILD_DIR)" SWIFT_FLAGS="$(SWIFT_FLAGS) -D SORELLO_SELFTEST"
	@set -e; $(SIM_RESOLVE); $(SIM_BOOT); \
	xcrun simctl terminate "$$udid" "$(BUNDLE_ID)" >/dev/null 2>&1 || true; \
	xcrun simctl install "$$udid" "$(E2E_BUILD_DIR)/Sorello.app"; \
	container=$$(xcrun simctl get_app_container "$$udid" "$(BUNDLE_ID)" data); \
	group=$$(xcrun simctl get_app_container "$$udid" "$(BUNDLE_ID)" "$(APP_GROUP)"); \
	mkdir -p "$$container/tmp"; \
	say -o "$(E2E_BUILD_DIR)/obj/synthetic-mic.wav" --data-format=LEI16@16000 "$(E2E_PHRASE)"; \
	mv "$(E2E_BUILD_DIR)/obj/synthetic-mic.wav" "$$container/$(E2E_AUDIO)"; \
	rm -f "$(E2E_LOG)"; \
	log="$(E2E_LOG)"; case "$$log" in /*) ;; *) log="$(CURDIR)/$$log" ;; esac; \
	SIMCTL_CHILD_SORELLO_SYNTHETIC_MIC="$(E2E_AUDIO)" \
	SIMCTL_CHILD_SORELLO_SYNTHETIC_HEADPHONES="$(E2E_HEADPHONES)" \
	SIMCTL_CHILD_SORELLO_SELFTEST_SKIP_ONBOARDING="$(E2E_SKIP_ONBOARDING)" \
	SIMCTL_CHILD_SORELLO_SELFTEST_SCREEN="$(E2E_SCREEN)" \
	SIMCTL_CHILD_SORELLO_SELFTEST_START_SESSION="$(E2E_START_SESSION)" \
		xcrun simctl launch --terminate-running-process --stdout="$$log" \
		"$$udid" "$(BUNDLE_ID)" >/dev/null; \
	echo "Sorello (self-test build, synthetic microphone) is running on $(E2E_SIM_DEVICE) $$udid."; \
	echo "  Window:        open -a Simulator --args -CurrentDeviceUDID $$udid"; \
	echo "  Keyboard:      Settings > General > Keyboard > Keyboards > Add New Keyboard > $(DISPLAY_NAME), then Allow Full Access"; \
	echo "  Every dictation hears the invented phrase \"$(E2E_PHRASE)\", then silence."; \
	echo "  Headless test: make -C iOS e2e-sim-probe [E2E_BACKGROUND=1 or E2E_FROM_BACKGROUND=1]"; \
	echo "  Shared files:  $$group/$(E2E_SHARED_DIR)"; \
	echo "  App output:    $(E2E_LOG) (content-free self-test lines only)"; \
	echo "  Shut down:     xcrun simctl shutdown $$udid"

# Shell fragment for the probes below, which play the keyboard's part through the
# shared files from the Mac: udid, dir, intent ACTION [REQUEST], presence, field
# KEY (from status.json), status_of REQUEST (phase/error or none), and
# launch_app [simctl launch options], which brings the app forward (or starts it
# again) with the synthetic microphone.
E2E_SHELL = udid=$$(xcrun simctl list devices | grep -F "    $(E2E_SIM_DEVICE) (" | grep -F "(Booted)" | head -n 1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'); \
	[ -n "$$udid" ] || { echo "$(E2E_SIM_DEVICE) is not booted; run make e2e-sim first." >&2; exit 1; }; \
	group=$$(xcrun simctl get_app_container "$$udid" "$(BUNDLE_ID)" "$(APP_GROUP)"); \
	dir="$$group/$(E2E_SHARED_DIR)"; mkdir -p "$$dir"; \
	request=$$(uuidgen); instance=$$(uuidgen); \
	intent() { printf '{"action":"%s","issuedAt":%s,"keyboardInstanceID":"%s","requestID":"%s","schema":1}' \
		"$$1" "$$(date +%s)" "$$instance" "$${2:-$$request}" > "$$dir/.e2e-intent.tmp"; mv "$$dir/.e2e-intent.tmp" "$$dir/intent.json"; }; \
	presence() { printf '{"keyboardInstanceID":"%s","schema":1,"seenAt":%s}' "$$instance" "$$(date +%s)" > "$$dir/.e2e-presence.tmp"; \
		mv "$$dir/.e2e-presence.tmp" "$$dir/presence.json"; }; \
	field() { plutil -extract "$$1" raw -o - "$$dir/status.json" 2>/dev/null || true; }; \
	status_of() { if [ "$$(field dictation.requestID)" = "$$1" ]; then echo "$$(field dictation.phase)/$$(field dictation.error)"; else echo none; fi; }; \
	launch_app() { SIMCTL_CHILD_SORELLO_SYNTHETIC_MIC="$(E2E_AUDIO)" SIMCTL_CHILD_SORELLO_SYNTHETIC_HEADPHONES="$(E2E_HEADPHONES)" \
		SIMCTL_CHILD_SORELLO_SELFTEST_SKIP_ONBOARDING="$(E2E_SKIP_ONBOARDING)" \
		xcrun simctl launch "$$@" "$$udid" "$(BUNDLE_ID)" >/dev/null; }

# Scripted round trip against an e2e-sim install: a record intent, the app brought
# to the foreground (as when the user opens it), a finish intent, then the result
# is compared with E2E_PHRASE. Prints phases and pass/fail only, never the
# transcript; the result file is claimed (deleted) afterwards. If the app has to
# start again, launch_app keeps the synthetic microphone.
e2e-sim-probe:
	@set -e; $(E2E_SHELL); \
	phase() { if [ "$$(field dictation.requestID)" = "$$request" ]; then field dictation.phase; else echo none; fi; }; \
	wait_for() { deadline=$$(( $$(date +%s) + $$2 )); last=; while :; do \
		p=$$(phase); [ "$$p" = "$$last" ] || { echo "  $$(date +%T) phase=$$p session=$$(field session) model=$$(field model)"; last=$$p; }; \
		case " $$1 " in *" $$p "*) return 0 ;; esac; [ "$$(date +%s)" -lt "$$deadline" ] || return 1; \
		if [ -n "$(E2E_KEEP_PRESENCE)" ]; then presence; fi; sleep 0.25; done; }; \
	if [ -n "$(E2E_FROM_BACKGROUND)" ]; then \
		[ "$$(field session)" = active ] || { echo "E2E_FROM_BACKGROUND needs an active session." >&2; exit 1; }; \
		presence; xcrun simctl launch "$$udid" com.apple.Preferences >/dev/null; sleep 1; presence; \
		echo "Request $$request: record intent with Sorello in the background"; \
		intent record; \
	else \
		echo "Request $$request: record intent, then Sorello to the foreground"; \
		intent record; \
		launch_app; \
		if [ -n "$(E2E_OPEN_URL)" ]; then xcrun simctl openurl "$$udid" "$(URL_SCHEME)://dictate"; fi; \
	fi; \
	wait_for "recording failed cancelled" 30 || { echo "Timed out before recording" >&2; exit 1; }; \
	[ "$$(phase)" = recording ] || { echo "Not recording: $$(field dictation.error)" >&2; exit 1; }; \
	if [ -n "$(E2E_BACKGROUND)" ]; then \
		presence; xcrun simctl launch "$$udid" com.apple.Preferences >/dev/null; \
		echo "  $$(date +%T) Sorello sent to the background; writing keyboard presence"; \
	fi; \
	end=$$(( $$(date +%s) + $(E2E_SPEAK_SECONDS) )); \
	while [ "$$(date +%s)" -lt "$$end" ]; do if [ -n "$(E2E_KEEP_PRESENCE)" ]; then presence; fi; sleep 0.5; done; \
	echo "  $$(date +%T) finish intent"; \
	intent finish; \
	wait_for "completed failed cancelled" $(E2E_TIMEOUT) || { echo "Timed out waiting for the result" >&2; exit 1; }; \
	p=$$(phase); \
	[ "$$p" = completed ] || { echo "Dictation $$p: $$(field dictation.error)" >&2; exit 1; }; \
	result="$$dir/result-$$request.json"; \
	[ -f "$$result" ] || { echo "Completed without a result file" >&2; exit 1; }; \
	norm() { tr 'A-Z' 'a-z' | tr -cd 'a-z \n' | tr -s ' ' | sed -E 's/^ +| +$$//g'; }; \
	actual=$$(plutil -extract text raw -o - "$$result" | norm); \
	expected=$$(printf '%s\n' "$(E2E_PHRASE)" | norm); \
	enter=$$(plutil -extract pressEnter raw -o - "$$result"); \
	rm -f "$$result"; \
	if [ "$$actual" = "$$expected" ]; then echo "e2e: result=pass transcript_match=true press_enter=$$enter"; \
	else echo "e2e: result=fail transcript_match=false press_enter=$$enter" >&2; exit 1; fi

# Contract scenarios against an e2e-sim install, each printing one pass/fail line:
# - cancel: a cancel intent ends a recording.
# - kill-relaunch: the app is killed while recording; relaunched while the record
#   intent is still fresh, it reports the request interrupted and never restarts it.
# - url-hint: with Sorello in the background and no session, a record intent and
#   <scheme>://dictate admit nothing (the simulator holds the URL behind its "Open
#   in …?" alert; the in-app background hint path is covered by host tests). Only
#   arriving in the foreground admits, judging freshness then: a fresh intent
#   records, and one past pendingRecordTTL is neither admitted nor rejected.
# Relaunches end any session; the app is left running with no session.
# Settings is opened once before the first case. The cases send the app to the background by launching Settings and
# waiting two seconds, and its first launch in a simulator takes far longer than that: a case that believes the app is
# behind Settings while it is still in front fails, because an app in front admits a fresh intent, as it should.
e2e-sim-scenarios:
	@set -e; $(E2E_SHELL); \
	until_phase() { i=0; while [ "$$(field dictation.requestID)" != "$$1" ] || [ "$$(field dictation.phase)" != "$$2" ]; do \
		sleep 0.25; i=$$((i + 1)); [ $$i -lt 120 ] || return 1; done; }; \
	pass() { echo "e2e-scenario: $$1 result=pass"; }; \
	fail() { echo "e2e-scenario: $$1 result=fail $$2" >&2; exit 1; }; \
	to_background() { xcrun simctl launch "$$udid" com.apple.Preferences >/dev/null; sleep 2; }; \
	xcrun simctl launch "$$udid" com.apple.Preferences >/dev/null; sleep 10; \
	r=$$(uuidgen); intent record "$$r"; launch_app; \
	until_phase "$$r" recording || fail cancel "not recording: $$(status_of "$$r")"; \
	intent cancel "$$r"; until_phase "$$r" cancelled || fail cancel "$$(status_of "$$r")"; \
	pass cancel; \
	r=$$(uuidgen); intent record "$$r"; launch_app; \
	until_phase "$$r" recording || fail kill-relaunch "not recording: $$(status_of "$$r")"; \
	run=$$(field hostRunID); xcrun simctl terminate "$$udid" "$(BUNDLE_ID)"; launch_app; \
	i=0; while [ "$$(field hostRunID)" = "$$run" ]; do sleep 0.25; i=$$((i + 1)); [ $$i -lt 60 ] || fail kill-relaunch "no new run"; done; \
	sleep 2; outcome=$$(status_of "$$r"); \
	[ "$$outcome" = failed/interrupted ] && [ "$$(field session)" = inactive ] || fail kill-relaunch "$$outcome session=$$(field session)"; \
	pass kill-relaunch; \
	to_background; \
	r=$$(uuidgen); intent record "$$r"; xcrun simctl openurl "$$udid" "$(URL_SCHEME)://dictate" || true; sleep 4; \
	[ "$$(status_of "$$r")" = none ] && [ "$$(field session)" = inactive ] && [ "$$(field model)" = notPrepared ] || \
		fail url-hint-background "$$(status_of "$$r") session=$$(field session) model=$$(field model)"; \
	launch_app; until_phase "$$r" recording || fail url-hint-foreground "$$(status_of "$$r")"; \
	pass url-hint-fresh; \
	intent cancel "$$r"; until_phase "$$r" cancelled || true; \
	launch_app --terminate-running-process; sleep 3; to_background; \
	r=$$(uuidgen); intent record "$$r"; xcrun simctl openurl "$$udid" "$(URL_SCHEME)://dictate" || true; \
	sleep $$(( 21 + 3 )); launch_app; sleep 3; \
	[ "$$(status_of "$$r")" = none ] && [ "$$(field session)" = inactive ] || fail url-hint-stale "$$(status_of "$$r") session=$$(field session)"; \
	pass url-hint-stale

clean:
	@# Each directory reaches the shell as one exact path, spaces and quotes included.
	rm -rf build $(call shell_quote,$(HOST_BUILD_DIR)) $(call shell_quote,$(BUILD_DIR)) $(call shell_quote,$(SMOKE_BUILD_DIR)) \
		$(call shell_quote,$(SMOKE_DEVICE_BUILD_DIR)) $(call shell_quote,$(E2E_BUILD_DIR))
