import SwiftUI

@main
struct FM1FlasherApp: App {
    init() {
        // stdout is fully-buffered (not line-buffered) when it's not a tty,
        // which is the case when devicectl's --console pipes it back to the
        // Mac — without this, print() debug logging only shows up once the
        // buffer fills or the app exits, which is useless for watching a
        // live hardware install.
        setvbuf(stdout, nil, _IONBF, 0)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
