export PATH := $(CURDIR)/.tools/bin:$(PATH)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
ifeq ($(shell uname -s),Darwin)
export SDKROOT := $(shell DEVELOPER_DIR="$(DEVELOPER_DIR)" xcrun --sdk macosx --show-sdk-path)
endif

.PHONY: setup lint lint-common lint-swift format test check generate-types check-generated apple-core apple-build integration setup-vrt vrt vrt-record vrt-capture
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
	uv run --no-project python scripts/check-architecture.py
	@if [ "$${SUWOP_CLEAN_CHECK:-0}" = "1" ]; then cargo clean; fi
	bash scripts/check-generated.sh

lint-swift:
	env swiftformat App Sources Tests VRT NativeAcceptance --lint --config .swiftformat
	env swiftlint lint --strict --quiet

lint: lint-common
	@if [ "$$(uname -s)" = Darwin ]; then $(MAKE) lint-swift; fi

format:
	env cargo fmt --all
	env ruff check --fix scripts
	env ruff format scripts
	@if [ "$$(uname -s)" = Darwin ]; then env swiftformat App Sources Tests VRT NativeAcceptance --config .swiftformat; fi

test:
	$(MAKE) test-infra
	bash scripts/test-tools.sh
	bash scripts/test-hooks.sh
	env cargo test --locked --workspace --all-features
	@if [ "$${SUWOP_CLEAN_CHECK:-0}" = "1" ]; then cargo clean; fi
	@if [ "$$(uname -s)" = Darwin ]; then \
		bash scripts/build-rust-apple.sh --host && \
		{ if [ "$${SUWOP_CLEAN_CHECK:-0}" = "1" ]; then cargo clean; fi; } && \
		swift test -Xswiftc -warnings-as-errors; \
	fi

check: lint
	@if [ "$${SUWOP_CLEAN_CHECK:-0}" = "1" ]; then cargo clean; fi
	$(MAKE) test

generate-types:
	cargo run --locked --quiet -p suwop-core --bin schema > /tmp/suwop-schema.json
	uv run --no-project python scripts/generate-swift.py Sources/SuwopShell/Generated/Types.swift < /tmp/suwop-schema.json

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

setup-vrt:
	bash scripts/install-simslim.sh

vrt-capture:
	bash scripts/vrt.sh --capture

vrt:
	bash scripts/vrt.sh

vrt-record:
	bash scripts/vrt.sh --record

.PHONY: apple-native-test
apple-native-test:
	bash scripts/apple-native-test.sh

.PHONY: sharing-test
sharing-test:
	xcodegen generate
	xcodebuild -project Suwop.xcodeproj -scheme SuwopSharing -destination 'platform=macOS' -derivedDataPath DerivedData/Sharing CODE_SIGNING_ALLOWED=NO test

.PHONY: test-infra
test-infra:
	uv run --no-project python -m unittest discover -s scripts -p 'test_*.py' -v
