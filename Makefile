# Pinned tools come from mise.toml/mise.lock (`make setup`); hooks need no shell activation.
export PATH := $(shell mise bin-paths 2>/dev/null | tr '\n' ':')$(PATH)
export CARGO_BUILD_JOBS ?= 2
APPLE_RUST_BUILD_ARGS ?=
APPLE_PACKAGE_CACHE := $(CURDIR)/DerivedData/SourcePackages
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export MACOSX_DEPLOYMENT_TARGET ?= 14.0
export IPHONEOS_DEPLOYMENT_TARGET ?= 17.0
ifeq ($(shell uname -s),Darwin)
export SDKROOT := $(shell DEVELOPER_DIR="$(DEVELOPER_DIR)" xcrun --sdk macosx --show-sdk-path)
endif

.PHONY: setup lint lint-common lint-swift format test check generate-types check-generated apple-core apple-build integration setup-vrt vrt vrt-record vrt-capture
MISE_INSTALL = mise install --locked $$(mise ls --local --no-header 2>/dev/null | awk '{print $$1}')

setup:
	$(MISE_INSTALL)
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
	$(MAKE) test-rust
	@if [ "$${SUWOP_CLEAN_CHECK:-0}" = "1" ]; then cargo clean; fi
	@if [ "$$(uname -s)" = Darwin ]; then $(MAKE) test-swift; fi

# The real Rust-to-Swift bridge; Apple-only.
.PHONY: test-swift
test-swift:
	bash scripts/build-rust-apple.sh --host
	@if [ "$${SUWOP_CLEAN_CHECK:-0}" = "1" ]; then cargo clean; fi
	swift test -Xswiftc -warnings-as-errors

check: lint
	@if [ "$${SUWOP_CLEAN_CHECK:-0}" = "1" ]; then cargo clean; fi
	$(MAKE) test

generate-types:
	cargo run --locked --quiet -p suwop-core --bin schema > /tmp/suwop-schema.json
	uv run --no-project python scripts/generate-swift.py Sources/SuwopShell/Generated/Types.swift < /tmp/suwop-schema.json

check-generated:
	bash scripts/check-generated.sh

apple-core:
	bash scripts/build-rust-apple.sh $(APPLE_RUST_BUILD_ARGS)
	@if [ "$${SUWOP_CLEAN_CHECK:-0}" = "1" ]; then \
		cargo clean && rm -rf Generated/RustSlices; \
	fi

apple-build: apple-core
	xcodegen generate
	xcodebuild -clonedSourcePackagesDirPath "$(APPLE_PACKAGE_CACHE)" -project Suwop.xcodeproj -scheme SuwopiOS -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData/iOS CODE_SIGNING_ALLOWED=NO build
	xcodebuild -clonedSourcePackagesDirPath "$(APPLE_PACKAGE_CACHE)" -project Suwop.xcodeproj -scheme SuwopmacOS -destination 'generic/platform=macOS' -derivedDataPath DerivedData/macOS CODE_SIGNING_ALLOWED=NO build

integration:
	bash scripts/immich-integration-test.sh

# simslim is a macOS entry in mise.toml.
setup-vrt:
	$(MISE_INSTALL)

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
	xcodebuild -clonedSourcePackagesDirPath "$(APPLE_PACKAGE_CACHE)" -project Suwop.xcodeproj -scheme SuwopSharing -destination 'platform=macOS' -derivedDataPath DerivedData/Sharing CODE_SIGNING_ALLOWED=NO test

# nextest runs every test binary in parallel processes; it does not run doctests.
# RUST_TEST_ARGS=--release runs the same suite against optimized builds.
RUST_TEST_ARGS ?=
.PHONY: test-rust
test-rust:
	env cargo nextest run --locked --workspace --all-features $(RUST_TEST_ARGS)
	env cargo test --locked --workspace --all-features --doc $(RUST_TEST_ARGS)

# Simulator test products shared by CI's simulator lanes (SUWOP_SIMULATOR_PRODUCTS).
.PHONY: simulator-products
simulator-products:
	bash scripts/simulator-products.sh DerivedData/SimulatorProducts/current

.PHONY: test-infra
test-infra:
	uv run --no-project python -B -m unittest discover -s scripts -p 'test_*.py' -v

.PHONY: private-video-mac-test
private-video-mac-test:
	bash scripts/private-video-mac-test.sh

.PHONY: private-live-mac-test
private-live-mac-test:
	bash scripts/private-live-mac-test.sh

.PHONY: vrt-ci-host
vrt-ci-host:
	bash scripts/vrt.sh --ci-lane host-snapshots

# One of the duration-balanced UI shards, e.g. make vrt-ci-ui-2.
vrt-ci-ui-%:
	bash scripts/vrt.sh --ci-lane ui-$*
