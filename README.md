# MTA Subway Screensaver

A macOS screensaver that shows every New York City subway train live. The trains are drawn on a copy of the official MTA subway map, either recolored for a black background (dark navy water, dark green parks) or in the paper map's own colors, with automatic switching between the two. Each train is a dot that glides along the track between stations and slips under the lines that pass over it. The screensaver shows a magnified section of the map centered on your home stations, with a next-train board on glass in one corner and a small overview of the whole map in another. If live data becomes unavailable, a time-lapse replays the last half hour at 20 times speed instead.

There are no pictures here, since every view of the app shows the MTA map, which stays out of the repository (see "Permissions and sharing"). Build it to see it.

The project has two halves:

- **A Python pipeline**, run in Jupyter: `subway_pipeline.ipynb`. It downloads the MTA schedule and map, works out the track geometry, matches every station to its place on the official map, and exports three files: the map as two PDFs (dark and light) and a network description (JSON).
- **A native Swift app**, in `swift/`. It reads those files, downloads the live train feeds every 30 seconds, and animates the trains. It builds three things from the same code: the `.saver` screensaver, a preview app for development, and a sandbox app for sending trains by hand.

The Python side does the heavy, once-in-a-while work. The Swift side does only what has to happen live, so the screensaver uses about 1 to 2% of one CPU core.


## Current status

| Milestone | State |
|---|---|
| M1. The map full screen on black | Done |
| M2. Live trains as dots, placed identically to the notebook | Done (754 of 754 trips match the notebook, 0.0000 map units apart) |
| M4 (brought forward). Split and close-up layouts, home-station picker, next-train board, smooth motion | Done in the preview app; motion is being tuned |
| M3. Installable screensaver: System Settings, Options sheet, clean stop | Done (demo installed 28 October 2026) |
| Light mode | Done: Dark, Light, Match the Mac, or Light by day (29 October 2026) |
| Later | Port smooth motion back to the notebook; Windows version; iPhone and iPad (see below) |

The notebook walkthrough has covered sections 1 and 2; section 3 is next.


## How it works

```
                 ONCE IN A WHILE (Python, Jupyter)                          LIVE (Swift, every second)
 ┌──────────────────────────────────────────────────────────────┐   ┌──────────────────────────────────────┐
 │                                                              │   │                                      │
 │  MTA static schedule (GTFS zip) ──┐                          │   │  MTA live feeds (8 × GTFS-Realtime)  │
 │                                   ├─► §2 schedule            │   │        │  every 30 s                 │
 │  data.ny.gov station list ────────┤   §3 track geometry      │   │        ▼                             │
 │                                   │   §4 official map match  │   │   FeedClient ──► trips               │
 │  Official MTA map (vector PDF) ───┘   §5–7 checks + views    │   │        │                             │
 │                                            │                 │   │        ▼                             │
 │                                            ▼                 │   │   Locator ──► which trains, where    │
 │                              §8 export ──► export/map_black.pdf ─┼─► MapDocument (map bitmap)          │
 │                                        └─► export/network.json ──┼─► SubwayNetwork                     │
 │                                                              │   │        │                             │
 └──────────────────────────────────────────────────────────────┘   │        ▼                             │
                                                                    │   MotionPlanner ──► glide / stop     │
                                                                    │        │                             │
                                                                    │        ▼                             │
                                                                    │   TrainLayers (Core Animation)       │
                                                                    │   NextTrains  (arrival board)        │
                                                                    └──────────────────────────────────────┘
```

The two exported files are the only contract between the halves. The Swift app never reads the schedule zip or the original map; everything it needs is in `export/`.

### Placing a train

The live feeds do not give train positions (there is no GPS). Each trip lists only the stops it has not reached yet, with predicted times. To place a train, the program:

1. Drops trips whose data is more than 5 minutes old.
2. Finds the stop the train last left. It matches the upcoming stops against the route's known stopping patterns.
3. Works out how far through the current hop the train is. It uses the predicted arrival time and the scheduled time for that hop.
4. Puts the dot that far along the track drawn on the official map.

Trains waiting at a terminal are drawn dimmed if they leave within 10 minutes, and hidden otherwise. These rules live in the notebook (§6 `locate`, §8 `locate_from_export`). They are ported exactly to Swift (`Locator.locate`). `tools/compare_swift_python.py` checks the two agree.

### Smooth motion

Real trains move very slowly at map scale: a typical hop is about 37 map units in 90 seconds, under one screen point per second. Moving every dot to its exact position once a second therefore looks frozen. `MotionPlanner` trades a little positional accuracy for motion you can see:

```
                    time to leave (arrive on time at cruise speed)
        ┌─────────┐ ─────────────────────────────────────────────► ┌────────────┐
        │ STOPPED │                                                │ TRAVELING  │
        │ gray    │ ◄───────────────────────────────────────────── │ white,     │
        └─────────┘          glide finished: at the station        │ larger     │
           │   ▲                                                   └────────────┘
  data says│   │ data says the train is behind us:                        ▲
  we are   │   │ keep waiting                                             │
  behind   └───┼──────────────────────────────────────────────────────────┘
               │   leave now; glide faster (up to the catch-up speed), one hop at a time
               │
     data says the train is somewhere unconnected (a reroute, a reassigned trip):
     fade out, fade in at the new place
```

- Each hop is one continuous Core Animation glide along the track. It eases out of the station and into the next one, and is never interrupted halfway.
- Trains glide at about 1.5 map units per second, roughly four times real speed, so a typical hop takes about 25 seconds. A train leaves its station at the moment that makes it arrive at the predicted time, so the extra speed becomes extra waiting at stations.
- Dots never jump backwards. When fresh data disagrees with the animation, a train that is ahead waits longer, and a train that is behind catches up hop by hop. Corrections (catching up, fading to a new place, moving a parked dot, fading out a train that left the data) each wait a delay of up to 12 seconds, fixed per train, so they trickle out after each download instead of all happening at once every 30 seconds.
- A moving train is a white dot with a soft glow, about a third larger than a stopped train, which is gray. Parked trains are smaller and darker. Size and color change together over 0.4 seconds.

### Time-lapse

The time-lapse is a backup for when live data is unavailable, and a testing tool. `TripHistory` records, from every download, when each train reached and left each station (the same method as the timing report below), keeping each trip's stations in order and its times consistent. `TimeLapse` replays the last 30 minutes at 20 times speed: half an hour plays in 90 seconds, then the loop restarts. Every time is known, so each hop is one glide lasting the real hop time divided by 20.

It takes over automatically when every feed fails and at least 5 minutes have been recorded (the history is kept in memory while the app runs); the offline note then reads "Live data unavailable since … · replaying the last 30 min". Live motion resumes as soon as a download succeeds. For testing, Debug > Force Time-lapse (Option-Command-T) or the `--time-lapse` launch option turns it on regardless; add `--time-lapse-after 60` to start it after one minute of history instead of five.

At 20 times speed there are dozens of stops and starts every second, so the time-lapse uses simpler motion: dots change between moving and stopped instantly instead of over 0.4 s, and glides (about 3 s each) skip the overpass masks. Measured on 29 October 2026, this brought the app from 6–13% of one core during the time-lapse to 2–4%, about the same as live motion. WindowServer (which draws every app's animations) stayed at about 45% whether the time-lapse or live motion was running (with the preview app's own live window also open), so the time-lapse adds little to it.

### When a download fails

`FeedCache` (in `FeedClient.swift`) keeps the last good download of each feed. A feed counts as failed on a network error, an HTTP error, unreadable data, or an empty response. When a feed fails, its trains keep following their predicted timetable instead of vanishing. The app retries after 10 seconds instead of 30. Held data is dropped once it is 5 minutes old (the stale limit). When every feed fails, a small note in the bottom-right corner reads "Live data unavailable since" and the time of the last good download.

On live data (95 seconds, 4 feed downloads): about 80 trains are gliding at any moment, the median hop takes 27 seconds, and real jumps are rare. Almost all jumps are parked placeholder dots that the MTA's data reassigns to a train elsewhere.

### Track paths

Each hop is drawn along the route's colored line on the official map. The PDF draws each color in several pieces (109 in all), so `mtamap.match.TrackNetwork` joins them: ends that touch, and ends that point straight at each other across a gap (where a line passes under a station's label box). A hop is the shortest route through that network between the two stations' circles. §8 exports every hop's path (`hop_paths` in network.json) so the app draws exactly the same tracks. 1,956 of the 2,084 hops in the stop patterns (94%) follow the track; the rest, about 1.5% of train trips, are drawn as straight lines, mostly around the Atlantic Av-Barclays Ctr transfer box.

A train rerouted onto another line's tracks (common at night and on weekends: the E through the 63 St tunnel, the F and D on the 8 Av line) can't follow its own colored line. It then follows the track of a route that normally runs between the two stations, or two such stretches through one station in between (an express skipping a stop). §8 exports these as `pair_paths`. On a night with several reroutes, `--path-audit` measured 1 glide in 366 off the drawn track.

Where the map draws one line over another (an overpass, such as the A/C/E and B/D/F/M over the 1/2/3 at Columbus Circle), trains on the lower line pass under it. §8 exports every route stroke in the map's drawing order (`route_strokes`: later strokes are on top, with each line's width including its black casing). Where a glide's path enters another line's band (within its half-width, black casing included), the train is under it if its own line is drawn earlier there (the 2/3 at Columbus Circle, overdrawn) or not drawn at all (the 1 there, which the map leaves out under the band and the track network bridges). Testing the band rather than the center line also catches a line drawn in two pieces that meet where the train passes (the orange B/D curve over the 1). A line the path follows for 8 map units or more is its own track, not a crossing. The app then masks the dot inside that line's band, so it slips under the black border and comes out on the far side; `--overpasses ROUTE FROM TO` lists the bands a hop passes under.

The station matching (§4) also separates stations that ended up on one circle group with a station they don't transfer to (for example, every Brighton line station had been matched one circle off), and applies `MAP_FIXES` for the few it still gets wrong. `--path-report` lists the remaining straight hops and draws them over the map.

### Timing accuracy

`--timing-report` compares each dot with the real train, using the feeds themselves as the reference. The real arrival is taken from the MTA's first report that the train is standing at the station. The real departure is the last time reported before the station drops off the trip's list. The feeds are read every 15 seconds, so each reference time is good to about 15 seconds.

While a train stands at a station, some lines (the A, C and E feed, for example) keep moving its reported arrival forward to the present. The last reported arrival is therefore really the departure, and it must not be used as the arrival.

Results from 3 minutes on 28 October 2026, afternoon, at the earlier cruise speed of 2.5 (glides of about 13 seconds). At 1.5 the arrivals are unchanged, since a dot always aims for the predicted arrival; departures are about 12 seconds closer to real.

| Measure | Median | Middle 80% | Within 30 s | Within 60 s |
|---|---|---|---|---|
| Dot reaches a station vs the real train | 3 s late | 25 s early to 32 s late | 79% | 95% |
| Dot reaches a station after a catch-up glide | 21 s late | 14 s early to 40 s late | 73% | 99% |
| Dot leaves a station vs the real train | 42 s late | 29 s early to 94 s late | 31% | 66% |

The dot arrives exactly when the MTA's prediction said it would (0 s difference in every case). All of the arrival error is the error in the MTA's own prediction at the moment the glide began. Departures are late by design: the dot waits at the station and then travels about six times faster than the real train, so it leaves later and arrives on time. In the middle of a hop, the dot is usually still at the previous station or just leaving it while the real train is already on its way.


## Folder layout

```
mta-screensaver/
├── README.md                  this file
├── requirements.txt           Python packages the notebook needs
├── subway_pipeline.ipynb      the pipeline (§1–§9 + two appendices); the reference for all rules
├── live_demo.ipynb            runs the pipeline and animates trains inline for N seconds (slow, ~2 fps)
├── fast_demo.py               matplotlib demo (its window does not appear on this Mac; kept for reference)
├── mtamap/                    reads, restyles and matches the official map PDF
│   ├── pdfreader.py           minimal PDF parser (incl. RC4 decryption of the MTA file)
│   ├── pdfdraw.py             draws PDF paths and text with matplotlib
│   ├── style.py               recoloring for a black background
│   ├── match.py               matches GTFS stations to the map's route circles; draws hops along the track
│   └── __init__.py            OfficialMap: station_point, hop_line, station_extent, draw
├── data/                      downloads and notebook figures (re-creatable)
│   ├── gtfs_subway.zip        MTA static schedule
│   ├── subway_diagram.pdf     official MTA map
│   ├── mta_stations.csv       data.ny.gov station list (uptown/downtown labels, boroughs)
│   └── *.png                  snapshots from the notebook
├── export/                    written by §8; bundled into the Swift app at build time
│   ├── map_black.pdf          the recolored map (black land, dark water and parks); 1 PDF point = 1 map unit (1656 × 1978)
│   ├── map_light.pdf          the same map in the paper map's colors, for light mode
│   └── network.json           stations, platforms, routes, stopping patterns, hop times, focus views
├── swift/                     the macOS app and screensaver (see swift/README.md)
│   ├── Shared/                code used by both targets
│   ├── PreviewApp/            the SubwayPreview development app
│   ├── Sandbox/               the SubwaySandbox app: send trains by hand (no live data)
│   ├── Saver/                 the SubwaySaver screensaver entry point
│   ├── SubwaySaver.xcodeproj  generated by tools/gen_xcodeproj.py
│   └── build/                 build output (safe to delete)
├── tools/
│   ├── gen_xcodeproj.py       regenerates the Xcode project file
│   ├── make_icons.swift       draws the app icons (preview app and sandbox)
│   ├── compare_swift_python.py  checks Swift places every train exactly where the notebook does
│   └── gtfs-realtime.desc     feed schema, for regenerating the Swift feed decoder
└── archive/                   earlier versions of the notebook
```


## Data sources

| Source | Used for | Key |
|---|---|---|
| [MTA GTFS static schedule](https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip) | Stations, stopping patterns, scheduled hop times, track shapes | None |
| [MTA GTFS-Realtime feeds](https://api.mta.info/) (`api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs…`, 8 feeds) | Live trips and predicted arrivals | None |
| [Official MTA subway map](https://www.mta.info/map/5256) (vector PDF) | The map itself, and where each station sits on it | None |
| [data.ny.gov MTA Subway Stations](https://data.ny.gov/Transportation/MTA-Subway-Stations/39hk-dx4f) | "Uptown" / "Downtown" labels per station, borough | None |

One round of the 8 live feeds is about 140 KB compressed. At one round every 30 seconds, that is about 17 MB per hour while the screensaver runs.


## Running it

### Installing on another Mac

Anyone can build this for their own personal use on their own Mac. The repository holds only the code: the map and the train data are not in it, so each person makes their own copy from the MTA's public files (which also keeps to the map's personal-use terms; see "Permissions and sharing").

What it needs:

- macOS 14 (Sonoma) or later, Apple Silicon or Intel.
- Xcode 16 or later, from the Mac App Store (the Command Line Tools alone are not enough). No Apple developer account: the build is signed for that Mac only. Xcode downloads the SwiftProtobuf package during the first build.
- Python 3 with the packages in `requirements.txt`. Anaconda's base environment has most of them; add the rest with `pip install -r requirements.txt`.
- An internet connection, to build and to run.

Steps, from the project folder:

1. Install the Python packages.

```bash
pip install -r requirements.txt
```

2. Run the notebook (about 2 minutes). It downloads the schedule, the official map and the station list, and writes `export/`: the dark and light maps and `network.json`.

```bash
jupyter nbconvert --to notebook --execute --inplace subway_pipeline.ipynb
```

3. Build and install the screensaver.

```bash
zsh tools/install_saver.sh
```

4. Choose **Subway** in System Settings > Screen Saver; **Options…** sets the stations, magnification and appearance.

The preview app and the sandbox are optional; their build commands are below and in `swift/README.md`. Homebrew and the protobuf tools are only needed to regenerate the feed decoder. The schedule in the export expires (currently on 15 May 2027): after that, repeat steps 2 and 3.

### The notebook

Open `subway_pipeline.ipynb` in Anaconda Navigator's Jupyter Notebook (the **base** environment, which has every package the notebook needs) and run it top to bottom. Every setting is in the single settings cell in §1. The first run downloads the schedule and the map; later runs reuse them.

To run it non-interactively:

```bash
~/anaconda3/bin/jupyter nbconvert --to notebook --execute --inplace ~/mta-screensaver/subway_pipeline.ipynb
```

### The preview app

Build with the scheme (a target build skips the SwiftProtobuf package), then open the app:

```bash
cd ~/mta-screensaver/swift && xcodebuild -project SubwaySaver.xcodeproj -scheme SubwayPreview -configuration Release -destination 'platform=macOS' -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages build
```

```bash
open ~/mta-screensaver/swift/build/DerivedData/Build/Products/Release/SubwayPreview.app
```

Or open `swift/SubwaySaver.xcodeproj` in Xcode, choose the SubwayPreview scheme and press Command-R.

The app has two layouts, chosen from the View menu and remembered between runs:

- **Split View** (Command-1): the whole map on the left. On the right, a magnified map of the home stations sits above the next-train board, which is only as tall as its content: three trains each way for one station, two for more.
- **Close-up** (Command-2): one section of the map fills the window at a readable zoom, centered on the home stations. A small overview of the whole map (top right) outlines the section shown, and the next-train board is a card in the bottom-left corner.

The magnified map's **magnification** is "Fit stations" (framed on your stations) or a fixed 2×, 3×, 4×, 6× or 8×: multiples of the whole map fitted to the screen, so they mean the same on any display. Choose it at the bottom of the tram-button panel; Command-plus and Command-minus step through the choices.

The tram button in the bottom-right corner opens the home-station picker. Your chosen stations (up to four, which is what the board has room for) are listed at the top, in the order the next-train board shows them, with buttons to reorder or remove them; a dot under a line's symbol marks lines serving one of them. Below are a search box, a row of route symbols for browsing one line's stations in order from its northern end, and every station grouped by borough with its route symbols and an Add / Added button. Control-Command-F toggles full screen.

### The sandbox

SubwaySandbox is a separate app for sending trains by hand and trying out new features. It uses no live data and shares no settings with the preview app or the screensaver, only the drawing and motion code, so it moves a train you send exactly as the screensaver would move a real one. Choose a route, two of its stations and a pace, then Send. You can make a train run late or jump ahead to watch how the motion corrects. Build it with the scheme `SubwaySandbox`; details are in [swift/README.md](swift/README.md#sandbox).

### iPhone and iPad

Most of the code would carry over: the network data, placing trains, the motion planner and the feed client are plain Swift with no Mac-only parts. What changes:

- **Drawing.** The map panel and the dots use Core Animation, which iOS has too; only the AppKit views (the board, the picker, the Options sheet) would be rewritten in UIKit or SwiftUI. The map PDF draws the same way.
- **Where it runs.** iOS has no screensavers. The closest equivalents are an app you leave open on a stand (with the screen kept awake), home-screen and lock-screen widgets (built with WidgetKit), and a Live Activity on the lock screen counting down to your next train.
- **What it needs.** An Apple developer account (99 dollars a year) to install on a phone for more than a week at a time, and an iOS target in the project.

### The screensaver

```bash
zsh ~/mta-screensaver/tools/install_saver.sh
```

This builds `SubwaySaver.saver` and copies it to `~/Library/Screen Savers`, then restarts macOS's screensaver host so the new version loads. Choose **Subway** in System Settings > Screen Saver. The screensaver always shows the close-up: the magnified map filling the screen, centered on your stations. Its **Options…** sheet sets those stations (up to four) and the magnification; the screensaver keeps its own settings, separate from the preview app's. Run the script again after any change (including a re-run of the notebook's export).

The screensaver shares one feed download among all its views (one per display, plus the thumbnail in System Settings), and stops all downloads and timers when macOS announces the screensaver is ending (`com.apple.screensaver.willstop`), since recent macOS does not always call `stopAnimation()`.

### Tests and measurements

All of these run the preview app's executable from Terminal:

```bash
cd ~/mta-screensaver/swift && APP=build/DerivedData/Build/Products/Release/SubwayPreview.app/Contents/MacOS/SubwayPreview
```

| Command | What it does |
|---|---|
| `$APP --snapshot out.png --live` | Renders the full view with live trains to a PNG, without a window |
| `$APP --snapshot out.png --live --layout closeUp --home 122,A21` | The same, in a given layout and with given home stations (the saved choices are unchanged) |
| `$APP --time-lapse-report --record 420 --seconds 60` | Records live history for 7 minutes, replays it, and checks every glide starts where its dot is |
| `$APP --path-audit --seconds 180` | Runs live motion and reports glides off the drawn track, position jumps and the slowest glides |
| `$APP --path-report out` | Checks the track every hop follows; writes `out.png` with straight hops in red |
| `$APP --picker-snapshot out.png --line A` | Renders the home-station picker (optionally browsing one line) |
| `swiftc -O tools/test_saver.swift -o /tmp/test_saver && /tmp/test_saver swift/build/DerivedData/Build/Products/Release/SubwaySaver.saver /tmp/saver` | Loads the built screensaver as macOS does, runs it on live data, renders it, measures CPU, and checks it stops on `willstop` |
| `$APP --timing-report --seconds 180` | Compares each dot's arrival at, and departure from, a station with when the real train got there |
| `$APP --dump-placements out.json --feeds-dir DIR --now UNIXTIME` | Places every trip from saved feeds and writes the positions |
| `$APP --plan-report --seconds 95` | Runs the motion planner on live data and reports glide speeds, trains in motion, catch-ups and jumps |
| `$APP --plan-report --simulate-outage gtfs-ace` | The same, with that feed (or `all`) failing after the first download |
| `open SubwayPreview.app --args --simulate-outage all` | Opens the preview window with every feed failing after the first download, to see the offline note |
| `~/anaconda3/bin/python ~/mta-screensaver/tools/compare_swift_python.py FEEDS_DIR $APP` | Downloads the feeds once, places trains in both Python and Swift, and compares them train by train |

The status line in the preview app shows the train counts and the app's own CPU use.


## Settings worth knowing

| Setting | Where | Default | Effect |
|---|---|---|---|
| `STALE_AFTER_S` | notebook §1 (exported) | 300 | Trips with older data are dropped |
| `PARK_WINDOW_S` | notebook §1 (exported) | 600 | Trains leaving a terminal within this many seconds are shown dimmed |
| `TRAIN_DOT_UNITS` | notebook §1 (exported) | 6.5 | Train dot size in map units, before on-screen limits |
| `FOCUS_VIEWS` | notebook §1 (exported) | 5 presets | Named groups of stations for magnified views |
| `cruiseSpeed` | `swift/Shared/MotionPlanner.swift` | 1.5 | Glide speed in map units per second. Higher means brisker motion and longer station waits; lower keeps dots closer to the real trains mid-hop |
| `WATER`, `PARKS` | `mtamap/style.py` | dark navy, dark green | Tints for water and parks on the black map (re-run §8 and rebuild after changing) |
| `catchUpSpeed` | `swift/Shared/MotionPlanner.swift` | 3.5 | Fastest glide when a train is behind the data |
| `correctionSpread` | `swift/Shared/MotionPlanner.swift` | 12 | Corrections wait up to this many seconds (fixed per train), so they don't all happen right after a download |
| `minTravelSeconds` | `swift/Shared/MotionPlanner.swift` | 4 | Shortest glide, so very short hops do not flick past |
| `maxTravelSeconds` | `swift/Shared/MotionPlanner.swift` | 40 | Longest glide: hops drawn long on the map (96 St to 110 St on the 2 and 3) glide faster instead of crawling |
| `pollInterval` | `swift/Shared/FeedClient.swift` (FeedHub) | 30 | Seconds between feed downloads |
| `retryInterval` | `swift/Shared/FeedClient.swift` (FeedHub) | 10 | Seconds before retrying after a round in which any feed failed |
| home stations | tram-button panel, or the screensaver's Options sheet | 79 St (1), 81 St (B, C) | Up to 4 stations, shown in the magnified view and on the next-train board |
| magnification | tram-button panel, Options sheet, Command-plus / minus | Fit stations | Fit stations, or 2× to 8× the whole map fitted to the screen |
| layout | View menu (saved) | Split View | Split View or Close-up |
| `MAP_FIXES` | notebook §1 | 6 stations | Stations the automatic map matching places on the wrong circles: station ID → a point on its correct circles (§4) |
| appearance | Appearance menu, or the Options sheet | Dark | Dark, Light, Match the Mac (follows System Settings > Appearance), or Light by day (7 AM to 7 PM; `dayStartHour` and `dayEndHour` in `swift/Shared/SubwaySettings.swift`) |
| train board | Appearance > Train Board, or the Options sheet | Glass | In the close-up, the next-train board sits on Liquid Glass (macOS 26; a frosted blur before), on clear glass (the map shows through unblurred; drawn by the board itself, since Apple's clear glass style looked like regular glass in the screensaver), or on a solid card. In the split layout it is always solid |
| text backdrops | Appearance > Train Board, or the Options sheet | on | On clear glass, a rounded patch behind the heading, the clock, each station name, the direction labels and each train, so the rest of the board can stay clear |
| glass tint | Appearance > Train Board, or the Options sheet (slider) | 30% | How strongly the glass is tinted with the theme's background: lower is more see-through, higher is easier to read over a busy map |
| `LAND_LIGHT` | `mtamap/style.py` | off-white | Land color of the light map (re-run §8 and rebuild after changing) |
| time-lapse | automatic when offline; Debug menu to force | off | Backup replay of the last 30 minutes at 20 times speed. `speed`, `window` and `minimumHistory` are in `swift/Shared/TimeLapse.swift` |

Settings marked "exported" take effect in the app only after re-running §8 and rebuilding.


## Refreshing the schedule

The MTA republishes the static schedule several times a year. The current export was built on 29 October 2026 from the fall 2026 schedule, valid **1 November 2026 to 15 May 2027**. To refresh:

1. Run the notebook. When the zip is older than `STATIC_MAX_AGE_DAYS`, §1 downloads a new schedule.
2. Check the §4 matching report. Every station should still be matched to the map; a new or renamed station would show up here.
3. Run §8. It re-exports the maps and `network.json`, and asserts the export still places trains exactly like §6.
4. Rebuild the Swift targets so they bundle the new files.


## Known limitations and risks

These are the issues most likely to affect how smoothly the app runs, roughly in order of urgency.

1. **The schedule expires on 15 May 2027.** The live feeds keep working afterwards, but any new stopping pattern or reroute in the next schedule is unknown to the app; trains on such patterns follow straight lines or cannot be placed. Refresh as described above once the MTA publishes the new file. (The current export, refreshed on 29 October, uses the schedule that starts on 1 November; until then a few live patterns, such as some A trains near Aqueduct, draw as straight lines.)
2. **macOS screensaver hosting.** Third-party screensavers run inside Apple's `legacyScreenSaver` process, which can keep running after the screensaver closes; the saver therefore stops on `com.apple.screensaver.willstop` (tested: 0.01% CPU afterwards). Its behavior on lock, sleep and wake, and with several displays, has not yet been tested on screen.
3. **Network and battery while the screensaver runs.** About 17 MB per hour and 1–2% of one core. That is fine while the Mac is plugged in. On battery, the app could poll less often or stop when the display sleeps.

   Memory was measured over 2 hours on 29 October 2026 (`test_saver --soak 7200`, with repeated screensaver stops and starts and a 45-minute internet outage during which the time-lapse took over): the screensaver stayed at 25–34 MB with no upward trend (+0.3 MB per hour, within noise), and Apple's screensaver host running it at 83–94 MB. The preview app held at 61–63 MB in its default window and settled at about 100 MB in a larger one (bigger map images).
4. **Two copies of the placement rules.** `locate` exists in Python and in Swift. A change to one must be made in the other and checked with `tools/compare_swift_python.py`. The smooth-motion planner exists only in Swift so far.
5. **Map gaps.** About 6% of hops (1.5% of trips) are still drawn as straight lines, mostly at the Atlantic Av-Barclays Ctr transfer box. A dot standing at a station covers that route's letter circle.
6. **No version control.** The project is not in its own git repository, so there is no history to return to if an edit goes wrong. The `archive/` folder holds only earlier notebook versions.


## Version control

The project is a private GitHub repository. It holds code only: the MTA's files (schedule, map, station list), the notebook's export and every image of the map are left out (see `.gitignore`), and notebooks are committed without their outputs. After cloning:

1. Set up the notebook filter once (it strips outputs when committing; your local notebooks keep theirs):
   ```bash
   git config filter.strip-notebook-outputs.clean "$HOME/anaconda3/bin/jupyter nbconvert --ClearOutputPreprocessor.enabled=True --to=notebook --stdin --stdout --log-level=ERROR" && git config filter.strip-notebook-outputs.smudge cat
   ```
2. Run `subway_pipeline.ipynb` top to bottom: it downloads the MTA files into `data/` and writes `export/`.
3. Build the app or install the screensaver as above.

The screensaver's thumbnail is local only, since it shows MTA artwork.

## Permissions and sharing

The map is MTA artwork. Its own notice says it may not be reproduced without the MTA's written permission, so the app and screensaver built from it are for personal use only. Share the code, not a built app or screensaver: each person builds their own (see "Installing on another Mac"). Appendix A of the notebook draws a generated diagram from the schedule alone. That diagram is the shareable fallback if this project is ever distributed.

The schedule and the live feeds are public MTA data and need no key.
