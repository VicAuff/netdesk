import AppKit
import CleanCore
import SwiftUI

/// Closing the window quits the app: nothing keeps running in the background.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct NetDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @LocalState private var app = AppState()

    var body: some Scene {
        Window(Product.name, id: "main") {
            ContentView()
                .environment(app)
                .tint(Theme.accent)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear { app.monitor.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    app.refreshAccess()
                }
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarMonitor().environment(app)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.selection) {
                ForEach(Module.sections, id: \.0) { title, modules in
                    Section {
                        ForEach(modules) { module in
                            Label(module.title, systemImage: module.symbol).tag(module)
                        }
                    } header: {
                        if !title.isEmpty { Text(title) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail(app.selection ?? .overview)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle(app.selection?.title ?? Product.name)
        }
        .task { await ViewDump.run(app) }
    }

    @ViewBuilder private func detail(_ module: Module) -> some View {
        switch module {
        case .overview: OverviewView()
        case .cleanup: CleanupView()
        case .trash: TrashBinsView()
        case .privacy: PrivacyView()
        case .performance: PerformanceView()
        case .applications: ApplicationsView()
        case .clutter: ClutterView()
        case .diskMap: DiskMapView(model: app.diskMap)
        case .monitor: MonitorView()
        case .screenCleaning: ScreenCleaningView()
        case .journal: JournalView()
        case .settings: SettingsView()
        }
    }
}
