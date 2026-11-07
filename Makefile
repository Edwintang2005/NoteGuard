# NoteGuard developer commands. The Xcode project is generated from project.yml.
.PHONY: project build release

XCODEGEN_VERSION := $(shell cat .xcodegen-version)
SIM_DEST := generic/platform=iOS Simulator

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

## Unsigned Release compile check (catches Debug-only code before archive day).
release: project
	xcodebuild -project NoteGuard.xcodeproj -scheme NoteGuard -destination "$(SIM_DEST)" \
		-configuration Release CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		-derivedDataPath build/DerivedData build
