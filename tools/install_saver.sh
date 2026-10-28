#!/bin/zsh
# Builds the screensaver (Release) and installs it for this user, in ~/Library/Screen Savers.
# Afterwards choose "Subway" in System Settings > Screen Saver (Options… sets the focus stations and magnification).
#
#   zsh ~/mta-screensaver/tools/install_saver.sh
set -e
cd "$(dirname "$0")/../swift"

xcodebuild -project SubwaySaver.xcodeproj -scheme SubwaySaver -configuration Release -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages build -quiet

target="$HOME/Library/Screen Savers"
mkdir -p "$target"
rm -rf "$target/SubwaySaver.saver"
cp -R build/DerivedData/Build/Products/Release/SubwaySaver.saver "$target/"

# macOS keeps the previously loaded version in memory until its screensaver host restarts; it starts again on demand.
killall legacyScreenSaver 2>/dev/null || true

echo "Installed $target/SubwaySaver.saver"
echo "Choose \"Subway\" in System Settings > Screen Saver. Options… sets the stations it focuses on and the magnification."
