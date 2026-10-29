// Loads the built screensaver the way macOS does and checks it works, without installing it or touching the
// screen: it runs the saver on live data, renders what it shows to a PNG, measures its CPU use, checks it stops
// when macOS announces the screensaver is ending, and renders its Options sheet.
//
// Build and run (from the mta-screensaver folder):
//   swiftc -O tools/test_saver.swift -o /tmp/test_saver
//   /tmp/test_saver swift/build/DerivedData/Build/Products/Release/SubwaySaver.saver /tmp/saver_test
// Writes <out>_screen.png and <out>_options.png.
//
// Long run: add --soak SECONDS to keep the saver running that long, printing its memory footprint (as Activity
// Monitor shows it) and CPU use every minute, then a summary; the other checks run afterwards.

import AppKit
import ScreenSaver

func cpuSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

/// This process's memory footprint in MB (what Activity Monitor shows as "Memory").
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

/// Runs the main loop for `seconds` and returns the CPU used meanwhile, as a percentage of one core.
func run(_ seconds: Double) -> Double {
    let start = cpuSeconds()
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    return (cpuSeconds() - start) / seconds * 100
}

func writePNG(_ image: CGImage, _ path: String) {
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let arguments = CommandLine.arguments
guard arguments.count >= 3, let bundle = Bundle(path: arguments[1]) else {
    print("usage: test_saver <SubwaySaver.saver> <output prefix> [--soak SECONDS]")
    exit(1)
}
let soakSeconds = arguments.firstIndex(of: "--soak").flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil }
let out = arguments[2]
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

guard bundle.load(), let saverClass = bundle.principalClass as? ScreenSaverView.Type else {
    print("FAIL: the bundle didn't load, or its principal class isn't a ScreenSaverView")
    exit(1)
}
print("loaded \(bundle.bundleIdentifier ?? "?"), principal class \(saverClass)")

let size = NSSize(width: 1512, height: 982)
guard let saver = saverClass.init(frame: NSRect(origin: .zero, size: size), isPreview: false) else {
    print("FAIL: init(frame:isPreview:) returned nil")
    exit(1)
}
// macOS puts the view in a full-screen window, which lays it out; do the same without a window.
saver.subviews.first?.frame = saver.bounds
saver.layoutSubtreeIfNeeded()
saver.subviews.first?.layoutSubtreeIfNeeded()
saver.startAnimation()
print("started; waiting for the first downloads...")
_ = run(15)
let cpuRunning = run(30)
print(String(format: "CPU while running: %.1f%% of one core", cpuRunning))


if let soakSeconds {
    // Sample once a minute: elapsed minutes, memory footprint, CPU over that minute.
    print("minute  memory MB  CPU %")
    var samples: [(minute: Double, mb: Double)] = []
    let start = Date()
    while Date().timeIntervalSince(start) < soakSeconds {
        // The real screensaver ending (macOS's "will stop" message reaches every Subway screensaver, this one
        // included) stops this copy too: start it again, as macOS does with the next screensaver session.
        saver.startAnimation()
        let cpu = run(60)
        let minute = Date().timeIntervalSince(start) / 60
        let mb = footprintMB()
        samples.append((minute, mb))
        print(String(format: "%6.0f  %9.1f  %5.1f", minute, mb, cpu))
        fflush(stdout)
    }
    // Growth: compare the average of the first and last quarter-hour (single samples are noisy).
    let early = samples.prefix(15).map(\.mb), late = samples.suffix(15).map(\.mb)
    let hours = (samples.last!.minute - samples.first!.minute) / 60
    let growth = (late.reduce(0, +) / Double(late.count) - early.reduce(0, +) / Double(early.count)) / max(hours, 1e-6)
    print(String(format: "soak: %.1f h; memory first %.1f MB, peak %.1f MB, last %.1f MB; trend %+.1f MB per hour",
                 hours, samples.first!.mb, samples.map(\.mb).max()!, samples.last!.mb, growth))
}

// What it shows: the layer tree (map, trains), then the AppKit-drawn views (next-train board) on top.
let scale: CGFloat = 2
let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
ctx.scaleBy(x: scale, y: scale)
let content = saver.subviews.first!
content.layer?.render(in: ctx)
for view in content.subviews where !view.isHidden {
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        if let image = rep.cgImage { ctx.draw(image, in: view.frame) }
    }
}
writePNG(ctx.makeImage()!, out + "_screen.png")

// macOS announces the end of the screensaver; everything should stop.
DistributedNotificationCenter.default().postNotificationName(.init("com.apple.screensaver.willstop"), object: nil,
                                                             userInfo: nil, deliverImmediately: true)
_ = run(2)
let cpuStopped = run(20)
print(String(format: "CPU after 'will stop': %.2f%% of one core", cpuStopped))

// The Options sheet.
if saver.hasConfigureSheet, let sheet = saver.configureSheet, let view = sheet.contentView {
    _ = run(0.5)  // let the sheet finish filling its station list
    view.appearance = NSAppearance(named: .darkAqua)
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
    view.frame = NSRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        writePNG(rep.cgImage!, out + "_options.png")
    }
    print("Options sheet: \(Int(view.fittingSize.width))×\(Int(view.fittingSize.height)) pt")
} else {
    print("FAIL: no Options sheet")
}
print(cpuStopped < 0.5 ? "PASS: stops when the screensaver ends" : "FAIL: still busy after 'will stop'")
exit(0)
