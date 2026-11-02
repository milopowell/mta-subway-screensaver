#!/bin/zsh
# One command from a fresh copy of the project to an installed screensaver:
#
#   zsh tools/setup.sh            (from the mta-screensaver folder)
#   zsh tools/setup.sh --apps     also install the preview app and the sandbox in ~/Applications
#
# It checks the Mac (macOS 14 or later, Xcode), sets up a private Python environment in .venv (nothing else on the Mac
# changes), runs the notebook to download the MTA's schedule, map and station list and draw the maps (about 2 minutes),
# then builds and installs the screensaver. Run it again at any time, for example after the MTA publishes a new
# schedule: steps already done go quickly. If a step fails, it says what went wrong and what to do.

cd "$(dirname "$0")/.." || exit 1
project=$PWD
with_apps=false
[[ "$1" == "--apps" ]] && with_apps=true

step() { print -P "\n%B==> $1%b" }
fail() {
    print -u2 -P "\n%BSetup stopped:%b $1"
    exit 1
}

# ---- 1. The Mac ----
step "Checking the Mac"
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || fail "this needs macOS 14 (Sonoma) or later; this Mac has $(sw_vers -productVersion)."
developer=$(xcode-select -p 2>/dev/null)
if [[ "$developer" != *Xcode*.app* ]]; then
    fail "this needs Xcode (free, from the Mac App Store; the Command Line Tools alone aren't enough).
Install it, open it once to finish installing, then run:
    sudo xcode-select -s /Applications/Xcode.app
and run this setup again."
fi
xcodebuild -version >/dev/null 2>&1 || fail "Xcode isn't ready to use yet. Open Xcode once (it may install extra parts and ask you to
agree to its license), or run:  sudo xcodebuild -license accept
then run this setup again."
print "macOS $(sw_vers -productVersion), $(xcodebuild -version | head -1)"

# ---- 2. Python ----
step "Setting up Python (in .venv; the first time takes a few minutes)"
python=$(command -v python3) || fail "Python 3 isn't installed. Installing Xcode normally adds it; run  xcode-select --install  if not."
"$python" -c 'import sys; sys.exit(sys.version_info < (3, 9))' \
    || fail "this needs Python 3.9 or later; $python is $("$python" --version 2>&1)."
if [[ ! -x .venv/bin/python ]]; then
    "$python" -m venv .venv || fail "couldn't create the Python environment in $project/.venv."
fi
.venv/bin/python -m pip install --quiet --upgrade pip >/dev/null 2>&1
.venv/bin/python -m pip install --quiet -r requirements.txt \
    || fail "couldn't install the Python packages. Check the internet connection and run this setup again.
(The details are just above.)"
print "Python packages ready ($(.venv/bin/python --version))"

# ---- 3. The notebook: MTA data and the maps ----
step "Downloading the MTA data and drawing the maps (about 2 minutes)"
started=$(date +%s)
run=$(mktemp -d)/subway_pipeline_run.ipynb  # the notebook as run, with its output (the original stays unchanged)
if ! .venv/bin/jupyter nbconvert --to notebook --execute subway_pipeline.ipynb \
        --ExecutePreprocessor.timeout=1800 --output-dir "$(dirname "$run")" --output "$(basename "$run")" \
        >/dev/null 2>"$run.log"; then
    tail -5 "$run.log" >&2
    fail "the notebook stopped with an error (the last lines are above; all of it is in $run.log).
If it says a download failed, check the internet connection and run this setup again."
fi
for f in map_black.pdf map_light.pdf network.json schedule.json; do
    [[ -f "export/$f" ]] && (( $(stat -f %m "export/$f") >= started )) \
        || fail "the notebook ran but didn't write export/$f. The run is saved in $run."
done
print "Maps and data written to export/"

# ---- 4. Build and install ----
step "Building and installing the screensaver"
zsh tools/install_saver.sh >"$run.saver.log" 2>&1 || {
    tail -15 "$run.saver.log" >&2
    fail "the screensaver didn't build (the last lines are above; all of it is in $run.saver.log)."
}
if $with_apps; then
    step "Building and installing the preview app and the sandbox"
    zsh tools/install_apps.sh >"$run.apps.log" 2>&1 || {
        tail -15 "$run.apps.log" >&2
        fail "the apps didn't build (the last lines are above; all of it is in $run.apps.log)."
    }
fi

step "Done"
print "Choose Subway in System Settings > Screen Saver. Its Options… button sets your stations, the magnification
and the appearance."
$with_apps && print "Subway Preview and Subway Sandbox are in your Applications folder (~/Applications)."
open "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension" 2>/dev/null || true
