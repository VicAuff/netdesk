import AppKit
import Combine
import ApplicationServices
import CleanCore
import SwiftUI

// MARK: - Monitor

struct MonitorView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let s = app.monitor.snapshot
        VStack(spacing: 0) {
            ModuleHeader(module: .monitor, subtitle: "Processeur, mémoire, disque et batterie, relevés toutes les 3 secondes tant que l'app est ouverte.") {
                EmptyView()
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    gauge("Processeur", "cpu", ratio: s.cpuUsage, value: "\(Int((s.cpuUsage * 100).rounded())) %", detail: "Charge moyenne de tous les cœurs")
                    gauge("Mémoire", "memorychip", ratio: s.memoryRatio, value: "\(Format.bytes(s.memoryUsed)) / \(Format.bytes(s.memoryTotal))",
                          detail: "Dont \(Format.bytes(s.memoryCompressed)) compressés")
                    gauge("Disque", "internaldrive", ratio: s.diskUsedRatio, value: "\(Format.bytes(s.diskAvailable)) libres",
                          detail: "Sur \(Format.bytes(s.diskTotal))")
                    if let level = s.batteryLevel {
                        gauge("Batterie", s.isCharging ? "battery.100.bolt" : "battery.75", ratio: Double(level) / 100, value: "\(level) %",
                              detail: s.isCharging ? "En charge" : "Sur batterie", inverted: true)
                    }
                    info("Allumé depuis", "clock", value: uptime(s.uptime))
                    info("Température", "thermometer.medium", value: thermal(s.thermalState))
                }
                .padding(20)
            }
        }
    }

    private func gauge(_ title: String, _ symbol: String, ratio: Double, value: String, detail: String, inverted: Bool = false) -> some View {
        let level = inverted ? 1 - ratio : ratio
        let color: Color = level > 0.85 ? Theme.danger : level > 0.65 ? Theme.warning : Theme.accent
        return VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            ProgressView(value: min(max(ratio, 0), 1)).tint(color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func info(_ title: String, _ symbol: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            Text(value).font(.title3.weight(.semibold))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func uptime(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86_400, hours = Int(seconds) % 86_400 / 3_600, minutes = Int(seconds) % 3_600 / 60
        return days > 0 ? "\(days) j \(hours) h" : "\(hours) h \(minutes) min"
    }

    private func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normale"
        case .fair: return "Tiède"
        case .serious: return "Élevée"
        case .critical: return "Critique"
        @unknown default: return "Inconnue"
        }
    }
}

struct MenuBarMonitor: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = app.monitor.snapshot
        VStack(alignment: .leading, spacing: 8) {
            row("cpu", "Processeur", "\(Int((s.cpuUsage * 100).rounded())) %")
            row("memorychip", "Mémoire", "\(Format.bytes(s.memoryUsed)) / \(Format.bytes(s.memoryTotal))")
            row("internaldrive", "Disque libre", Format.bytes(s.diskAvailable))
            if let level = s.batteryLevel { row("battery.75", "Batterie", "\(level) %") }
            Divider()
            Button("Ouvrir \(Product.name)") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Button("Quitter") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func row(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

// MARK: - Screen cleaning

/// Swallows keyboard and trackpad input so the screen can be wiped. Hold Escape 2 seconds to leave; stops by itself after 90 seconds.
@MainActor
final class ScreenCleaner {
    static let shared = ScreenCleaner()
    static let maxDuration: TimeInterval = 90

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var windows: [NSWindow] = []
    private var escapeDownSince: Date?
    private var autoStop: Timer?
    private(set) var isActive = false

    func start() -> Bool {
        guard !isActive, AXIsProcessTrusted() else { return false }
        var mask: UInt64 = 0
        for type: CGEventType in [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                  .otherMouseDown, .otherMouseUp, .scrollWheel, .leftMouseDragged, .rightMouseDragged] {
            mask |= 1 << UInt64(type.rawValue)
        }
        mask |= 1 << 14 // System-defined events: brightness, volume, media keys.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: screenCleanerCallback, userInfo: nil) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        showWindows()
        isActive = true
        escapeDownSince = nil
        autoStop = Timer.scheduledTimer(withTimeInterval: Self.maxDuration, repeats: false) { _ in
            Task { @MainActor in ScreenCleaner.shared.stop() }
        }
        return true
    }

    func stop() {
        guard isActive else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        autoStop?.invalidate()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        isActive = false
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let escape: Int64 = 53
        if event.getIntegerValueField(.keyboardEventKeycode) == escape {
            if type == .keyDown {
                if let since = escapeDownSince {
                    if Date().timeIntervalSince(since) >= 2 { DispatchQueue.main.async { ScreenCleaner.shared.stop() } }
                } else {
                    escapeDownSince = Date()
                }
            } else if type == .keyUp {
                escapeDownSince = nil
            }
        }
        return nil
    }

    private func showWindows() {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: ScreenCleaningOverlay())
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSCursor.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSCursor.unhide() }
    }
}

private func screenCleanerCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    MainActor.assumeIsolated { ScreenCleaner.shared.handle(type: type, event: event) }
}

struct ScreenCleaningOverlay: View {
    @LocalState private var remaining = Int(ScreenCleaner.maxDuration)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.white.opacity(0.5))
            Text("Clavier et trackpad bloqués, tu peux essuyer.").font(.title2).foregroundStyle(.white.opacity(0.7))
            Text("Maintiens Échap 2 secondes pour sortir · arrêt automatique dans \(remaining) s")
                .font(.callout).monospacedDigit().foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onReceive(timer) { _ in remaining = max(0, remaining - 1) }
    }
}

struct ScreenCleaningView: View {
    @LocalState private var trusted = AXIsProcessTrusted()
    @LocalState private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .screenCleaning, subtitle: "Écran noir, clavier et trackpad bloqués le temps d'essuyer l'écran.") {
                EmptyView()
            }
            VStack(spacing: 16) {
                Image(systemName: "display").font(.system(size: 54)).foregroundStyle(Theme.accent)
                Text("Maintiens Échap 2 secondes pour sortir. Sécurité : arrêt automatique au bout de \(Int(ScreenCleaner.maxDuration)) secondes.")
                    .multilineTextAlignment(.center).frame(maxWidth: 420).foregroundStyle(.secondary)
                if trusted {
                    Button("Commencer") { failed = !ScreenCleaner.shared.start() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                    if failed { Text("Impossible de bloquer la saisie.").foregroundStyle(Theme.danger) }
                } else {
                    Text("Bloquer le clavier demande l'autorisation Accessibilité.").foregroundStyle(Theme.warning)
                    HStack {
                        Button("Demander l'autorisation") {
                            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            trusted = AXIsProcessTrustedWithOptions(options)
                        }
                        Button("Vérifier") { trusted = AXIsProcessTrusted() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
