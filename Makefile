# Everyday commands. ARCHITECTURE.md, section 10, says what each produces.
.PHONY: build test check app run snapshots clean

build:
	swift build

test:
	swift test

# What every change must pass. Needs no model and no network.
check:
	./scripts/check-rules.sh
	swift build
	swift test

# build/<name>.app. SORELLO_MODEL_DIR=<pinned bundle> puts the model in; CHANNEL=nightly builds "Sorello Nightly" and
# CHANNEL=release "Sorello", both universal.
# ARCHS="arm64 x86_64" chooses the architectures; a development build is otherwise for this Mac only.
app:
	./scripts/build-app.sh

run: app
	open "$$(./scripts/build-app.sh | tail -1)"

snapshots:
	swift run SorelloSnapshots build/snapshots

clean:
	rm -rf .build build
