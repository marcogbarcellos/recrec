APP        := RecRec
BUNDLE_ID  := com.barsmike.RecRec
VERSION    ?= 0.2.0
# Signing identity: a stable identity keeps the Screen Recording permission across rebuilds (ad-hoc "-"
# signatures change with every build and macOS treats each build as a new app). Auto-detects the
# "RecRec Development" certificate created by `make signing-cert`; override with SIGN="Apple Development: …".
SIGN       ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"RecRec Development"' && echo "RecRec Development" || echo "-")
DIST       := dist/$(APP).app
ifeq ($(UNIVERSAL),1)
  ARCHS    := --arch arm64 --arch x86_64
  BUILD    := .build/apple/Products/Release
else
  ARCHS    :=
  BUILD    := .build/release
endif

.PHONY: build test app run bench clean signing-cert icon release install

build:
	swift build -c release $(ARCHS)

test:
	swift run RecRecTests

app: build
	rm -rf "$(DIST)"
	mkdir -p "$(DIST)/Contents/MacOS" "$(DIST)/Contents/Resources"
	cp "$(BUILD)/$(APP)" "$(DIST)/Contents/MacOS/$(APP)"
	cp Packaging/AppIcon.icns "$(DIST)/Contents/Resources/AppIcon.icns"
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

# Regenerate Packaging/AppIcon.icns and docs/assets/logo-*.png from tools/icon/make-icon.swift.
icon:
	mkdir -p .build/icon && swift tools/icon/make-icon.swift .build/icon
	iconutil -c icns .build/icon/AppIcon.iconset -o Packaging/AppIcon.icns
	cp .build/icon/logo-512.png docs/assets/logo-512.png
	cp .build/icon/logo-128.png docs/assets/logo-128.png

# Build, copy to /Applications (replacing any previous copy) and relaunch from there.
install: app
	-osascript -e 'tell application "$(APP)" to quit' >/dev/null 2>&1; sleep 1
	rm -rf "/Applications/$(APP).app"
	ditto "$(DIST)" "/Applications/$(APP).app"
	open "/Applications/$(APP).app"
	@echo "Installed /Applications/$(APP).app"

# Zip the built app for a GitHub release: dist/RecRec-$(VERSION).zip
release: app
	cd dist && rm -f "$(APP)-$(VERSION).zip" && ditto -c -k --keepParent "$(APP).app" "$(APP)-$(VERSION).zip" && ls -l "$(APP)-$(VERSION).zip"

# One-time: create a self-signed "RecRec Development" code-signing certificate in the login keychain so
# that rebuilds keep their Screen Recording permission. macOS may ask for your password to trust it.
signing-cert:
	@security find-identity -v -p codesigning | grep -q '"RecRec Development"' && echo "RecRec Development certificate already exists" && exit 0; \
	set -e; WORK=$$(mktemp -d); cd "$$WORK"; \
	printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=RecRec Development\n[v3]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n' > ext.cnf; \
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config ext.cnf -keyout key.pem -out cert.pem 2>/dev/null; \
	openssl pkcs12 -export -legacy -out dev.p12 -inkey key.pem -in cert.pem -name "RecRec Development" -passout pass:recrec 2>/dev/null || openssl pkcs12 -export -out dev.p12 -inkey key.pem -in cert.pem -name "RecRec Development" -passout pass:recrec; \
	security import dev.p12 -k ~/Library/Keychains/login.keychain-db -P recrec -T /usr/bin/codesign -T /usr/bin/security; \
	security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem; \
	rm -rf "$$WORK"; security find-identity -v -p codesigning | grep "RecRec Development"
