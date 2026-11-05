import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PixViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup("PixView") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { library.open(url: $0) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("폴더 열기…") { library.chooseFolder() }
                    .keyboardShortcut("o")
            }
        }
    }
}
