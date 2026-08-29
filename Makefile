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

.PHONY: all build test generate app clean

all: build test

## Build the UI-free core.
build:
	$(SWIFT) build

## Run the core test suite (fixtures only; never touches /Applications or brew).
test:
	$(SWIFT) test

## Generate the Xcode project for the SwiftUI app shell from project.yml.
generate:
	$(XCODEGEN) generate

## Compile the app shell. Signing is disabled so this works on a clean machine.
app: generate
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=macOS' \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
		build

clean:
	$(SWIFT) package clean
	rm -rf .build $(PROJECT)
