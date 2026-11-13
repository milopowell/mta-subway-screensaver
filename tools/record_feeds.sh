#!/bin/zsh
# Records the live MTA feeds for the motion check (tools/check.sh replays every recording in data/recordings/).
#
#   zsh tools/record_feeds.sh 60       record for 60 minutes (the default), into data/recordings/<date>_<time>/
#
# A download every 30 seconds, like the app, each saved as it came (about 80 MB an hour). The Mac is kept awake while
# it records (caffeinate). Late nights and weekends are worth recording: that's when trains run their odd patterns
# (locals on express lines, reroutes). A recording of something that looked wrong can be kept, and the check then
# replays it after every change.

cd "$(dirname "$0")/.." || exit 1
minutes=${1:-60}
app=swift/build/DerivedData/Build/Products/Release/SubwayPreview.app/Contents/MacOS/SubwayPreview
[[ -x $app ]] || { print -u2 "Build the preview app first (zsh tools/check.sh builds it)."; exit 1; }

# Its own copy of the app, so rebuilding while it records doesn't disturb it.
copy=$(mktemp -d)/SubwayPreview.app
cp -R ${app:h:h:h} $copy
dir=data/recordings/$(date '+%Y-%m-%d_%H%M')
mkdir -p $dir
print "Recording $minutes minutes into $dir (Ctrl-C stops it; what's recorded so far is kept)"
caffeinate -i $copy/Contents/MacOS/SubwayPreview --record-feeds $dir --seconds $(( minutes * 60 ))
