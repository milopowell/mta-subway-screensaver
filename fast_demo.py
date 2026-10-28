"""Fast live demo in a native macOS window: the official map with live trains, redrawn with blitting.

Unlike live_demo.ipynb (which re-sends a whole image to the browser every frame), this keeps the rendered map
in memory and repaints only the train dots each frame, which is how the real screensaver should work.
At the end it prints the frame rate achieved and how much CPU the process used.

Run from Terminal (in ~/mta-screensaver, with Anaconda's base Python):
    ~/anaconda3/bin/python fast_demo.py                       # whole map, 60 s, 30 fps
    ~/anaconda3/bin/python fast_demo.py --view Midtown --seconds 45
    ~/anaconda3/bin/python fast_demo.py --fullscreen
Close the window (or press Ctrl-C in Terminal) to stop early.
"""
import argparse
import contextlib
import io
import threading
import time
from pathlib import Path

import matplotlib
import nbformat

PIPELINE = Path(__file__).with_name("subway_pipeline.ipynb")


def load_pipeline():
    """Run the code cells of subway_pipeline.ipynb (§1–§8, not the appendices) and return their variables.

    Figures are drawn off-screen and discarded while it runs; only the functions and tables are kept.
    """
    matplotlib.use("Agg")  # no windows while the pipeline runs
    import matplotlib.pyplot as plt

    plt.show = lambda *args, **kwargs: None  # the pipeline's own charts aren't needed here
    ns = {"__name__": "pipeline"}
    with contextlib.redirect_stdout(io.StringIO()):  # hide the pipeline's printed log
        for cell in nbformat.read(PIPELINE, 4).cells:
            if cell.cell_type == "markdown" and cell.source.lstrip().startswith("---\n# Appendix"):
                break  # the appendices aren't needed for the demo
            if cell.cell_type == "code":
                exec(compile(cell.source, str(PIPELINE), "exec"), ns)
                plt.close("all")
    return ns


def bring_to_front():
    """Make the demo the frontmost app so its window isn't hidden behind Terminal or other windows.

    Anaconda's Python isn't a macOS "framework" build, so on its own its windows open *behind* whatever app
    you're using. AppKit (part of pyobjc, included with Anaconda) asks macOS to activate this process.
    """
    try:
        from AppKit import NSApplication, NSApplicationActivationPolicyRegular

        app = NSApplication.sharedApplication()
        app.setActivationPolicy_(NSApplicationActivationPolicyRegular)  # a normal app: Dock icon, can take focus
        app.activateIgnoringOtherApps_(True)
    except Exception as err:  # without pyobjc the demo still runs; the window may just open behind others
        print(f"Couldn't bring the window to the front ({err}); look for the Python icon in the Dock.")


class Feed:
    """Downloads the live feeds in a background thread every `poll_s` seconds, so the animation never waits."""

    def __init__(self, fetch_all, poll_s):
        self.fetch_all, self.poll_s = fetch_all, poll_s
        self.trains, self.fetched_at = fetch_all()  # first download happens before the window opens
        self.downloads, self._stop = 1, threading.Event()
        self._lock = threading.Lock()
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while not self._stop.wait(self.poll_s):
            try:
                trains, fetched_at = self.fetch_all()
            except Exception as err:  # a failed download keeps the old data; try again next time
                print(f"feed download failed ({err}); keeping previous data")
                continue
            with self._lock:
                self.trains, self.fetched_at = trains, fetched_at
                self.downloads += 1

    def latest(self):
        """(trains, fetched_at) from the most recent successful download."""
        with self._lock:
            return self.trains, self.fetched_at

    def stop(self):
        self._stop.set()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--seconds", type=float, default=60, help="how long to run (default 60)")
    parser.add_argument("--fps", type=float, default=30, help="target frames per second (default 30)")
    parser.add_argument("--view", default=None, help='a FOCUS_VIEWS name, e.g. "Midtown" (default: whole map)')
    parser.add_argument("--poll", type=float, default=30, help="seconds between feed downloads (default 30)")
    parser.add_argument("--fullscreen", action="store_true", help="fill the screen like a screensaver")
    args = parser.parse_args()

    print("Loading the pipeline (about 30 s)…")
    t_load = time.time()
    p = load_pipeline()
    print(f"Loaded in {time.time() - t_load:.0f} s")
    np, pd, omap, locate = p["np"], p["pd"], p["omap"], p["locate"]

    # ---- open a native window and draw the map once ----
    import matplotlib.pyplot as plt

    plt.switch_backend("macosx")
    if args.view:
        x0, x1, y0, y1 = p["focus_box"](p["resolve_stations"](p["FOCUS_VIEWS"][args.view]))
    else:
        x0, x1, y0, y1 = 0, p["mtamap"].PAGE_W, 0, p["mtamap"].MAP_H
    height_in = 9.0
    fig = plt.figure(figsize=(height_in * (x1 - x0) / (y1 - y0), height_in), facecolor="black")
    fig.canvas.manager.set_window_title("MTA live demo")
    ax = fig.add_axes([0, 0, 1, 1])
    pts_per_unit = omap.draw(ax, xlim=(x0, x1), ylim=(y0, y1))
    if args.fullscreen:
        try:
            fig.canvas.manager.full_screen_toggle()
        except Exception:
            print("Full screen isn't supported by this matplotlib backend; showing a normal window.")

    # ---- the only things redrawn each frame: three groups of dots and a status line ----
    dot_pt = max(p["TRAIN_DOT_UNITS"] * pts_per_unit, 4.5)  # train dot diameter in points
    size = dot_pt ** 2  # marker area in points²
    edge = dot_pt / 8
    empty = np.empty((0, 2))
    ring = dict(s=size * 2.6, facecolors="none", linewidths=edge * 2.5, animated=True)
    parked_dots = ax.scatter(empty[:, 0], empty[:, 1], edgecolors="#777777", zorder=10, **ring)
    station_dots = ax.scatter(empty[:, 0], empty[:, 1], edgecolors="white", zorder=11, **ring)
    moving_dots = ax.scatter(empty[:, 0], empty[:, 1], s=size, c="white", edgecolors="black", linewidths=edge,
                             zorder=12, animated=True)
    status = ax.text(0.01, 0.01, "", transform=ax.transAxes, color="white", fontsize=9, animated=True,
                     bbox=dict(facecolor="black", edgecolor="none", pad=3), zorder=13)
    artists = [parked_dots, station_dots, moving_dots, status]

    plt.show(block=False)
    bring_to_front()
    plt.pause(0.5)  # let the window appear and draw the map
    background = fig.canvas.copy_from_bbox(fig.bbox)  # the rendered map, kept in memory
    print('Window "MTA live demo" is open. If you can\'t see it, click the Python icon in the Dock.')

    feed = Feed(p["fetch_all"], args.poll)
    plan = {"fetched_at": None, "fixed": None, "moving": None}  # per-download work, reused every frame

    def replan(trains, fetched_at):
        """Once per download: place every train, and remember which ones move between frames."""
        placed = pd.DataFrame([locate(t, fetched_at) for _, t in trains.iterrows()],
                              columns=["x", "y", "how"], index=trains.index)
        moving = placed["how"].str.startswith("between")
        plan.update(fetched_at=fetched_at, fixed=placed[~moving].dropna(subset=["x", "y"]),
                    moving=trains[moving])

    start, cpu_start = time.time(), time.process_time()
    frames, frame_times = 0, []
    try:
        while time.time() - start < args.seconds and plt.fignum_exists(fig.number):
            t_frame = time.time()
            trains, fetched_at = feed.latest()
            if plan["fetched_at"] != fetched_at:
                replan(trains, fetched_at)
            # Moving trains: re-run locate() with the clock advancing, so they glide along their lines.
            now = time.time()
            moving_xy = np.array([locate(t, now)[:2] for _, t in plan["moving"].iterrows()]).reshape(-1, 2)
            moving_xy = moving_xy[~np.isnan(moving_xy).any(axis=1)]
            fixed = plan["fixed"]
            parked = fixed["how"].str.startswith("parked")
            parked_dots.set_offsets(fixed.loc[parked, ["x", "y"]].to_numpy())
            station_dots.set_offsets(fixed.loc[~parked, ["x", "y"]].to_numpy())
            moving_dots.set_offsets(moving_xy)
            fps_now = frames / max(time.time() - start, 1e-9)
            status.set_text(f"{args.view or 'Whole map'}  ·  {time.strftime('%-I:%M:%S %p')}  ·  "
                            f"{len(moving_xy)} trains moving  ·  data {now - fetched_at:.0f} s old  ·  "
                            f"{fps_now:.0f} fps  ·  {max(0, args.seconds - (now - start)):.0f} s left")
            # Blit: paste the saved map, draw only the dots and text on top, push to the screen.
            fig.canvas.restore_region(background)
            for artist in artists:
                ax.draw_artist(artist)
            fig.canvas.blit(fig.bbox)
            fig.canvas.flush_events()
            frames += 1
            frame_times.append(time.time() - t_frame)
            time.sleep(max(0.0, 1 / args.fps - (time.time() - t_frame)))
    except KeyboardInterrupt:
        print("Stopped early.")
    finally:
        feed.stop()
    elapsed = time.time() - start
    cpu = (time.process_time() - cpu_start) / elapsed * 100
    work_ms = 1000 * float(np.median(frame_times)) if frame_times else float("nan")
    print(f"\n{frames} frames in {elapsed:.0f} s = {frames / elapsed:.1f} fps (target {args.fps:g}); "
          f"median work per frame {work_ms:.1f} ms; {feed.downloads} feed downloads")
    print(f"CPU: {cpu:.0f}% of one core on average (Python + matplotlib; a native Swift version would be far lower)")
    plt.close("all")


if __name__ == "__main__":
    main()
