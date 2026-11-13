#!/bin/zsh
# The motion check: one command that runs every test of how the trains move and compares the results with the last
# saved ones, so a change can't quietly make the motion worse.
#
#   zsh tools/check.sh            run the checks; fails if any count of problems went up
#   zsh tools/check.sh --update   run them and save the results as the new reference (after checking a change is good)
#
# What it runs (the preview app, built in Release first):
#   1. the line runs (--line-runs): one train along every stop pattern of every line, each move checked;
#   2. for each recording in data/recordings/ (made with tools/record_feeds.sh): the recording replayed through the
#      app's motion (--replay), and through the time-lapse (--replay --time-lapse), each move checked.
# Results go in data/check/latest/ (the counts as JSON, the reports as text); the reference is data/check/reference/.
# Both stay out of the repository, like the recordings and the map: they depend on the MTA's data.

cd "$(dirname "$0")/.." || exit 1
update=false
[[ "$1" == "--update" ]] && update=true
latest=data/check/latest
reference=data/check/reference
rm -rf $latest
mkdir -p $latest $reference

fail() {
    print -u2 -P "\n%BCheck stopped:%b $1"
    exit 1
}

# ---- 1. Build ----
print -P "%B==> Building the preview app%b"
(cd swift && xcodebuild -project SubwaySaver.xcodeproj -scheme SubwayPreview -configuration Release \
    -destination 'platform=macOS' -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
    build -quiet) >$latest/build.log 2>&1 || { tail -15 $latest/build.log >&2; fail "the build failed (all of it is in $latest/build.log)."; }
app=swift/build/DerivedData/Build/Products/Release/SubwayPreview.app/Contents/MacOS/SubwayPreview

# ---- 2. Line runs ----
print -P "%B==> Line runs (every stop pattern, about 20 s)%b"
$app --line-runs --json $latest/line-runs.json >$latest/line-runs.txt 2>&1 || fail "the line runs stopped (see $latest/line-runs.txt)."

# ---- 3. Recordings ----
recordings=(data/recordings/*(N/))
(( ${#recordings} )) || print "No recordings in data/recordings/ (make one with: zsh tools/record_feeds.sh 60)"
for rec in $recordings; do
    name=${rec:t}
    print -P "%B==> Replaying $name%b"
    $app --replay $rec --json $latest/$name.json >$latest/$name.txt 2>&1 || fail "replaying $name stopped (see $latest/$name.txt)."
    $app --replay $rec --time-lapse --json $latest/$name.time-lapse.json >$latest/$name.time-lapse.txt 2>&1 \
        || fail "the time-lapse of $name stopped (see $latest/$name.time-lapse.txt)."
done

# ---- 4. Compare with the reference ----
if $update; then
    cp $latest/*.json $reference/
    print -P "\n%BSaved%b these results as the reference ($reference)."
    exit 0
fi
python3 - $latest $reference <<'EOF'
import json, sys
from pathlib import Path

latest, reference = Path(sys.argv[1]), Path(sys.argv[2])
worse = False
for now_file in sorted(latest.glob("*.json")):
    now = json.loads(now_file.read_text())
    saved_file = reference / now_file.name
    saved = json.loads(saved_file.read_text()) if saved_file.exists() else None
    print(f"\n{now_file.stem}" + ("" if saved else "  (new: no reference yet)"))
    for kind, count in sorted(now.items()):
        # Glides and runs are how much was checked, not problems.
        if kind in ("glides", "runs"):
            print(f"  {kind:28} {count}")
            continue
        before = saved.get(kind) if saved else None
        mark = ""
        if before is not None and count > before:
            mark, worse = f"   WORSE (was {before})", True
        elif before is not None and count < before:
            mark = f"   better (was {before})"
        print(f"  {kind:28} {count}{mark}")
print()
if worse:
    print("Some counts went up: see the reports in", latest, "(the .txt files list each problem).")
    sys.exit(1)
print("No count went up. If this change is good, save it as the reference: zsh tools/check.sh --update")
EOF
