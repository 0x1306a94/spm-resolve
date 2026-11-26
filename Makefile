VERSION := $(shell sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' Sources/spm-resolve/ToolVersion.swift)
PRODUCT := spm-resolve
BINARY := .build/release/$(PRODUCT)
DIST := dist
ARCHIVE := $(DIST)/$(PRODUCT)-$(VERSION).zip

.PHONY: all build zip sha256 clean

all: sha256

build:
	swift build -c release --product $(PRODUCT)

zip: build
	mkdir -p $(DIST)
	rm -f $(ARCHIVE)
	zip -j $(ARCHIVE) $(BINARY)

sha256: zip
	shasum -a 256 $(ARCHIVE) | tee $(ARCHIVE).sha256

clean:
	rm -rf $(DIST)
