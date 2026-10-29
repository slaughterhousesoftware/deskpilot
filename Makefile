ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
DERIVED := $(ROOT)App/DerivedData

.PHONY: kit-test live-test project app run clean


kit-test:
	swift test --package-path $(ROOT)

live-test:
	DESKPILOT_LIVE=1 swift test --package-path $(ROOT) --filter LiveDeskTests

project:
	cd $(ROOT)App && xcodegen generate

app: project
	xcodebuild -project $(ROOT)App/DeskpilotBar.xcodeproj -scheme DeskpilotBar -configuration Release \
	  -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

run: app
	pkill -x Deskpilot || true
	sleep 1
	open $(DERIVED)/Build/Products/Release/Deskpilot.app

clean:
	rm -rf $(DERIVED) $(ROOT).build

# Build the separate history/settings window.
dashboard: project
	xcodebuild -project $(ROOT)App/DeskpilotBar.xcodeproj -scheme DeskpilotDashboard -configuration Release \
	  -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

rust-test:
	cargo test --manifest-path $(ROOT)rust/Cargo.toml --workspace --all-features
