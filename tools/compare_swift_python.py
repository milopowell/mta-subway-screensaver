"""Place trains from the same saved feeds with the notebook's locate_from_export (Python) and the Swift Locator,
then compare train by train.

Usage: python compare_swift_python.py <feeds_dir> <swift_app_executable>
Downloads the 8 feeds into <feeds_dir> (as <feed>.pb), runs both, prints the comparison.
"""
import json
import subprocess
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import nbformat
import numpy as np
import pandas as pd
import requests

PROJECT = Path(__file__).resolve().parents[1]  # ~/mta-screensaver
sys.path.insert(0, str(PROJECT))
import mtamap  # noqa: E402  (the notebook's own package; locate_from_export uses mtamap.match.hop_line)
from google.transit import gtfs_realtime_pb2  # noqa: E402
from shapely.geometry import LineString  # noqa: E402

feeds_dir, swift_exe = Path(sys.argv[1]), sys.argv[2]
feeds_dir.mkdir(parents=True, exist_ok=True)
nb = nbformat.read(PROJECT / "subway_pipeline.ipynb", 4)
code = [c.source for c in nb.cells if c.cell_type == "code"]

# 1. Save one snapshot of all feeds, and fix "now" to the download time.
net = json.loads((PROJECT / "export/network.json").read_text())
now = time.time()
for feed in net["settings"]["feeds"]:
    r = requests.get(net["settings"]["feed_url"].format(feed), timeout=15)
    r.raise_for_status()
    (feeds_dir / f"{feed}.pb").write_bytes(r.content)

# 2. Python: the notebook's own fetch_all() (§5), reading the saved files instead of the network.
fetch_cell = next(c for c in code if "def fetch_all():" in c)
ns = {"time": time, "pd": pd, "requests": requests, "gtfs_realtime_pb2": gtfs_realtime_pb2,
      "FEEDS": net["settings"]["feeds"], "FEED_URL": net["settings"]["feed_url"]}
exec(fetch_cell.split("trains, fetched_at = fetch_all()")[0], ns)  # definitions only


def fetch_feed_from_file(name):
    msg = gtfs_realtime_pb2.FeedMessage()
    msg.ParseFromString((feeds_dir / f"{name}.pb").read_bytes())
    return msg


ns["fetch_feed"] = fetch_feed_from_file
trains, _ = ns["fetch_all"]()

# 3. Python: the notebook's locate_from_export (§8), definitions only, reading the same network.json.
check_cell = next(c for c in code if "def locate_from_export(" in c)
ns2 = {"json": json, "np": np, "pd": pd, "defaultdict": defaultdict, "Counter": Counter, "mtamap": mtamap,
       "LineString": LineString, "EXPORT_JSON": PROJECT / "export/network.json"}
exec(check_cell.split("check = pd.DataFrame(")[0], ns2)
python_rows = {(t["feed"], t["trip_id"]): ns2["locate_from_export"](t, now) for _, t in trains.iterrows()}

# 4. Swift: the same feeds and the same "now".
out = feeds_dir / "swift_placements.json"
run = subprocess.run([swift_exe, "--dump-placements", str(out), "--feeds-dir", str(feeds_dir), "--now", repr(now)],
                     capture_output=True, text=True)
print(run.stdout.strip() or run.stderr.strip())
swift_rows = {(r["feed"], r["trip_id"]): (r["x"], r["y"], r["how"]) for r in json.loads(out.read_text())}

# 5. Compare.
keys = set(python_rows) | set(swift_rows)
missing = [k for k in keys if k not in python_rows or k not in swift_rows]
same_how = sum(python_rows[k][2] == swift_rows[k][2] for k in keys if k not in missing)
dists = []
for k in keys:
    if k in missing:
        continue
    (px, py, _), (sx, sy, _) = python_rows[k], swift_rows[k]
    if (px != px) != (sx is None):  # drawn in one but not the other
        dists.append(float("inf"))
    elif sx is not None:
        dists.append(float(np.hypot(px - sx, py - sy)))
print(f"trips: Python {len(python_rows)}, Swift {len(swift_rows)}, in only one: {len(missing)}")
print(f"same category: {same_how} of {len(keys) - len(missing)}")
print(f"drawn trains compared: {len(dists)}; largest position difference: {max(dists):.4f} map units")
diff = [(k, python_rows[k][2], swift_rows[k][2]) for k in keys if k not in missing and python_rows[k][2] != swift_rows[k][2]]
for k, a, b in diff[:10]:
    print("  differs:", k, "python:", a, "| swift:", b)
print("categories:", dict(Counter(r[2] for r in python_rows.values())))
