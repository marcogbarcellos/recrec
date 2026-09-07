APP        := RecRec
BUNDLE_ID  := com.barsmike.RecRec
VERSION    ?= 0.1.0
SIGN       ?= -
DIST       := dist/$(APP).app
ifeq ($(UNIVERSAL),1)
  ARCHS    := --arch arm64 --arch x86_64
  BUILD    := .build/apple/Products/Release
else
  ARCHS    :=
  BUILD    := .build/release
endif

.PHONY: build test app run bench clean

build:
	swift build -c release $(ARCHS)

test:
	swift run RecRecTests

app: build
	rm -rf "$(DIST)"
	mkdir -p "$(DIST)/Contents/MacOS" "$(DIST)/Contents/Resources"
	cp "$(BUILD)/$(APP)" "$(DIST)/Contents/MacOS/$(APP)"
	sed -e 's/__VERSION__/$(VERSION)/g' Packaging/Info.plist > "$(DIST)/Contents/Info.plist"
	printf 'APPL????' > "$(DIST)/Contents/PkgInfo"
	codesign --force --sign "$(SIGN)" --identifier $(BUNDLE_ID) "$(DIST)"
	@echo "Built $(DIST)"; du -sh "$(DIST)"; ls -l "$(DIST)/Contents/MacOS/$(APP)" | awk '{print "binary:", $$5, "bytes"}'

run: app
	open "$(DIST)"

bench:
	mkdir -p .build/bench && swiftc -O -o .build/bench/encbench tools/encbench/encbench.swift
	.build/bench/encbench --scale 2 --seconds 60 --set core --outdir .build/bench/out --ref 5,15,45
	tools/encbench/quality.sh .build/bench/out 3456x2234

clean:
	rm -rf .build dist
