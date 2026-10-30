#!/bin/zsh
# Builds the preview app and the sandbox (Release) and installs them in ~/Applications, replacing earlier copies, so
# Spotlight, Launchpad and the Dock find them. Run it again after any change to the code or the notebook's export.
#
#   zsh ~/mta-screensaver/tools/install_apps.sh
#
# Each installed copy is stamped with the commit it was built from and the date (shown in its About window), noting
# uncommitted changes when there were any. The build folder is hidden from Spotlight, so searching "Subway" finds only
# the installed copies. Settings are kept: macOS stores them by the app's identity, not its location.

set -e
cd "$(dirname "$0")/../swift"

# The version stamp: the commit, whether the working tree differs from it, and today's date.
commit=$(git rev-parse --short HEAD)
if [[ -n "$(git status --porcelain)" ]]; then
    stamp="Commit $commit plus uncommitted changes, $(date '+%-d %b %Y %H:%M')"
else
    stamp="Commit $commit, $(date '+%-d %b %Y')"
fi

target="$HOME/Applications"
mkdir -p "$target"
mkdir -p build && touch build/.metadata_never_index  # keep Spotlight out of the build folder
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

for app in SubwayPreview SubwaySandbox; do
    xcodebuild -project SubwaySaver.xcodeproj -scheme $app -configuration Release -destination 'platform=macOS' \
        -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages build -quiet

    # Quit it if it's running (the copy here is about to be replaced), then install the new build.
    osascript -e "quit app id \"$(defaults read "$PWD/build/DerivedData/Build/Products/Release/$app.app/Contents/Info" CFBundleIdentifier)\"" \
        2>/dev/null || true
    rm -rf "$target/$app.app"
    ditto "build/DerivedData/Build/Products/Release/$app.app" "$target/$app.app"

    # Stamp the installed copy, then sign it again (changing an app after it's built breaks its signature).
    plutil -replace SubwayBuild -string "$stamp" "$target/$app.app/Contents/Info.plist"
    codesign --force --sign - "$target/$app.app" 2>/dev/null

    # macOS should open the installed copy, not the one in the build folder.
    $lsregister -u "$PWD/build/DerivedData/Build/Products/Release/$app.app" 2>/dev/null || true
    $lsregister -f "$target/$app.app"
    echo "Installed $target/$app.app ($stamp)"
done
