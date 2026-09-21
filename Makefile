# OpenFreshr — Makefile
#
# Two build paths on purpose:
#   * The Swift package (OpenFreshrCore + tests) builds and tests without Xcode,
#     signing or a running window server. This is the green DoD gate.
#   * XcodeGen turns project.yml into OpenFreshr.xcodeproj for the SwiftUI shell.
#
# Toolchain locations are pinned because a GUI-launched process does not inherit
# the interactive shell PATH; the same reason OpenFreshr resolves `brew`
# explicitly at runtime.

SWIFT ?= /usr/bin/swift
XCODEBUILD ?= /usr/bin/xcodebuild
XCODEGEN ?= /opt/homebrew/bin/xcodegen

PROJECT := OpenFreshr.xcodeproj
SCHEME := OpenFreshr

# Signing identity used by `make run`. A Developer ID gives the app a stable
# code identity; override on the command line if a different one is wanted.
# The team id is read out of the identity name, e.g. "… (G69Z5BNY97)".
SIGN_IDENTITY ?= Developer ID Application
DEVELOPMENT_TEAM ?= $(shell security find-identity -v -p codesigning \
	| grep -m1 "$(SIGN_IDENTITY)" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')

.PHONY: all build lint format test generate app run clean

all: build lint test

## Build the UI-free core.
build:
	$(SWIFT) build

## Check formatting with the toolchain's swift-format, configured by .swift-format.
## `make format` rewrites the files instead of only reporting.
lint:
	$(SWIFT) format lint --strict --recursive Sources Tests

format:
	$(SWIFT) format --in-place --recursive Sources Tests

## Run the core test suite (fixtures only; never touches /Applications or brew).
test:
	$(SWIFT) test

## Generate the Xcode project for the SwiftUI app shell from project.yml.
generate:
	$(XCODEGEN) generate

## Compile the app shell. Signing is disabled so this works on a clean machine.
##
## The resulting bundle is ad-hoc (linker-)signed and therefore has no stable
## code identity: `codesign -dvv` reports `Signature=adhoc` and the identifier
## degrades to the binary name rather than PRODUCT_BUNDLE_IDENTIFIER. macOS
## cannot persist a TCC grant against such a bundle, so a launched app re-asks
## for authorisation on every start. Use `make run` to actually use the app.
app: generate
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=macOS' \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
		build

## Build with a real signing identity and launch. This is the target to use for
## hands-on testing: a stable code identity lets macOS remember its consent
## decisions instead of prompting on every launch.
run: generate
	@set -e; \
	test -n "$(DEVELOPMENT_TEAM)" || { \
		echo "No signing identity matching '$(SIGN_IDENTITY)' found."; \
		echo "Run 'security find-identity -v -p codesigning' and pass"; \
		echo "SIGN_IDENTITY=... (and DEVELOPMENT_TEAM=... if needed)."; \
		exit 1; }; \
	built=$$($(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=macOS' -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}'); \
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=macOS' \
		CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" \
		build; \
	app="$$built/$(SCHEME).app"; \
	codesign -dvv "$$app" 2>&1 | grep -E 'Identifier|TeamIdentifier|Signature'; \
	open "$$app"

clean:
	$(SWIFT) package clean
	rm -rf .build $(PROJECT)
