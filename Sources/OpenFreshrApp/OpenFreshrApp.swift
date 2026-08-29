import SwiftUI

/// The application entry point. A single window hosting the split-view UI over a
/// shared ``AppViewModel``; an initial scan kicks off as soon as the window
/// appears.
@main
struct OpenFreshrApp: App {

    @State private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .frame(minWidth: 820, minHeight: 520)
                .task { await viewModel.scan() }
        }
        .windowResizability(.contentSize)
    }
}
