# NoteGuard developer commands. The Xcode project is generated from project.yml.
.PHONY: project build release test icon

XCODEGEN_VERSION := $(shell cat .xcodegen-version)
SIM_DEST := generic/platform=iOS Simulator
# Newest available iPad simulator (NoteGuard is iPad-only).
IPAD_SIM = $(shell xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for r in sorted(d, reverse=True) if "iOS" in r for x in d[r] if x["name"].startswith("iPad")))')

## Regenerate NoteGuard.xcodeproj (refuses a different XcodeGen version than CI uses).
project:
	@test "$$(xcodegen --version | awk '{print $$2}')" = "$(XCODEGEN_VERSION)" || \
		{ echo "XcodeGen $(XCODEGEN_VERSION) required (see .xcodegen-version)"; exit 1; }
	xcodegen generate

## Unsigned Debug compile check, warnings as errors (what CI runs).
build: project
	xcodebuild -project NoteGuard.xcodeproj -scheme NoteGuard -destination "$(SIM_DEST)" \
		-configuration Debug CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		-derivedDataPath build/DerivedData build

## Unit tests on an iPad simulator (what CI runs).
test: project
	xcodebuild test -project NoteGuard.xcodeproj -scheme NoteGuard -destination "id=$(IPAD_SIM)" \
		CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES -derivedDataPath build/DerivedData

## Re-render the app icon from tools/make_icon.swift.
icon:
	swift tools/make_icon.swift NoteGuard/Assets.xcassets/AppIcon.appiconset/AppIcon.png

## Unsigned Release compile check (catches Debug-only code before archive day).
release: project
	xcodebuild -project NoteGuard.xcodeproj -scheme NoteGuard -destination "$(SIM_DEST)" \
		-configuration Release CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		-derivedDataPath build/DerivedData build
