// Application entry point (architecture §4.6). The NSApplication principal
// class comes from Info.plist; here we only attach the delegate and run.
//
// Top-level code is nonisolated; everything after this point is main-actor,
// so we adopt the main actor explicitly once, before the runloop starts.

import AppKit

setvbuf(stdout, nil, _IOLBF, 0) // line-buffered: survive hard kills when redirected

let app = NSApplication.shared
MainActor.assumeIsolated {
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
}

app.run()
