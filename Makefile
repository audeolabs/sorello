# Everyday commands. ARCHITECTURE.md, section 10, says what each produces.
.PHONY: build test check app run snapshots clean legacy-check legacy-app

build:
	swift build

test:
	swift test

# What every change must pass. Needs no model and no network. TEST_FLAGS=--no-parallel runs the tests one at a
# time, which a Mac with few cores needs: run together there, the heavy tests starve the ones that wait on a clock.
check:
	./scripts/check-rules.sh
	swift build
	swift test $(TEST_FLAGS)

# build/<name>.app. SORELLO_MODEL_DIR=<pinned bundle> puts the model in; CHANNEL=nightly builds "Sorello Nightly" and
# CHANNEL=release "Sorello", both universal.
# ARCHS="arm64 x86_64" chooses the architectures; a development build is otherwise for this Mac only.
app:
	./scripts/build-app.sh

run: app
	open "$$(./scripts/build-app.sh | tail -1)"

snapshots:
	swift run SorelloSnapshots build/snapshots

# The build for older Macs (ARCHITECTURE.md, section 15): the same source built for macOS 13 and later, in its own
# directory, .build-legacy. legacy-check builds it and runs every test against it on this Mac; legacy-app makes
# build/legacy/<name>.app.
legacy-check:
	SORELLO_LEGACY=1 swift build --scratch-path .build-legacy
	SORELLO_LEGACY=1 swift test --scratch-path .build-legacy $(TEST_FLAGS)

legacy-app:
	SORELLO_LEGACY=1 ./scripts/build-app.sh

clean:
	rm -rf .build build
