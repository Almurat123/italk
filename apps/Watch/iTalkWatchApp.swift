import SwiftUI

@main struct iTalkWatchApp: App {
    @State private var model = AppModel()
    var body: some Scene { WindowGroup { WatchAssistantView().environment(model) } }
}
