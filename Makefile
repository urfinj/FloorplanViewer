# FloorplanViewer — developer tasks.
# XcodeGen is the only project source; never hand-edit the .xcodeproj.

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.DEFAULT_GOAL := help
SCHEME := FloorplanViewer
# Pin the OS so the destination resolves on machines that also have newer runtimes.
# Any installed iOS 17+ simulator is acceptable.
DESTINATION ?= platform=iOS Simulator,name=iPhone 15 Pro,OS=17.2

.PHONY: help generate format lint build test

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

generate: ## Regenerate FloorplanViewer.xcodeproj from project.yml
	xcodegen generate

format: ## Apply SwiftFormat in place
	swiftformat .

lint: ## Run the single lint lane (SwiftFormat --lint then SwiftLint --strict)
	./scripts/lint.sh

build: generate ## Build the app for the iOS simulator (fails on any build error)
	xcodebuild build -project FloorplanViewer.xcodeproj -scheme $(SCHEME) \
		-destination '$(DESTINATION)' | xcbeautify

test: generate ## Run the Swift Testing suite on the simulator
	xcodebuild test -project FloorplanViewer.xcodeproj -scheme $(SCHEME) \
		-destination '$(DESTINATION)' | xcbeautify
