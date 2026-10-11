export PATH := $(CURDIR)/.tools/bin:$(PATH)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
ifeq ($(shell uname -s),Darwin)
export SDKROOT := $(shell DEVELOPER_DIR="$(DEVELOPER_DIR)" xcrun --sdk macosx --show-sdk-path)
endif

.PHONY: setup lint lint-common lint-swift format test check generate-types check-generated apple-core apple-build integration
setup:
	bash scripts/install-tools.sh
	bash scripts/install-hooks.sh

lint-common:
	bash scripts/check-tools.sh
	env cargo fmt --all -- --check
	env cargo clippy --locked --workspace --all-targets --all-features -- -D warnings
	env ruff check scripts
	env ruff format --check scripts
	env shellcheck scripts/*.sh .githooks/*
	env actionlint
	python3 scripts/check-architecture.py
	bash scripts/check-generated.sh

lint-swift:
	env swiftformat App Sources Tests --lint --config .swiftformat
	env swiftlint lint --strict --quiet

lint: lint-common
	@if [ "$$(uname -s)" = Darwin ]; then $(MAKE) lint-swift; fi

format:
	env cargo fmt --all
	env ruff check --fix scripts
	env ruff format scripts
	@if [ "$$(uname -s)" = Darwin ]; then env swiftformat App Sources Tests --config .swiftformat; fi

test:
	bash scripts/test-tools.sh
	bash scripts/test-hooks.sh
	env cargo test --locked --workspace --all-features
	@if [ "$$(uname -s)" = Darwin ]; then bash scripts/build-rust-apple.sh --host && swift test -Xswiftc -warnings-as-errors; fi

check: lint test

generate-types:
	cargo run --locked --quiet -p suwop-core --bin schema > /tmp/suwop-schema.json
	python3 scripts/generate-swift.py Sources/SuwopShell/Generated/Types.swift < /tmp/suwop-schema.json

check-generated:
	bash scripts/check-generated.sh

apple-core:
	bash scripts/build-rust-apple.sh

apple-build: apple-core
	xcodegen generate
	xcodebuild -project Suwop.xcodeproj -scheme SuwopiOS -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData/iOS CODE_SIGNING_ALLOWED=NO build
	xcodebuild -project Suwop.xcodeproj -scheme SuwopmacOS -destination 'generic/platform=macOS' -derivedDataPath DerivedData/macOS CODE_SIGNING_ALLOWED=NO build

integration:
	bash scripts/immich-integration-test.sh
