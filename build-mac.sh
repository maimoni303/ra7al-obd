#!/bin/bash
# Build on any Mac (e.g. the iMac): generates the project, runs tests, outputs an unsigned IPA.
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
xcodebuild test -project RA7ALOBDProbe.xcodeproj -scheme RA7ALOBDProbe \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project RA7ALOBDProbe.xcodeproj -scheme RA7ALOBDProbe -configuration Release \
  -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
rm -rf Payload && mkdir Payload
cp -R build/Build/Products/Release-iphoneos/RA7ALOBDProbe.app Payload/
zip -qry RA7AL-OBD-Probe-unsigned.ipa Payload
echo "Done: $(pwd)/RA7AL-OBD-Probe-unsigned.ipa"
