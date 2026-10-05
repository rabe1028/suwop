.PHONY: test test-release immich-up immich-down integration-test xcodegen

IMMICH_COMPOSE = docker compose -f docker/immich-test/docker-compose.yml

test:
	swift test

test-release:
	swift test -c release

immich-up:
	$(IMMICH_COMPOSE) up -d

immich-down:
	$(IMMICH_COMPOSE) down -v --remove-orphans

integration-test:
	bash ./scripts/immich-integration-test.sh

xcodegen:
	xcodegen generate
