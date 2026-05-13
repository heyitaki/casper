// CASPER: SwiftUI hot-reload shim. In DEBUG builds, johnno1962/InjectionLite
// watches Casper source files, recompiles changed `.swift` files, dlopen()s the
// resulting dylib, and posts `INJECTION_BUNDLE_NOTIFICATION` once the swap
// succeeds. We observe that notification and bump a per-view UUID so SwiftUI
// invalidates and re-evaluates the view body with the freshly-loaded code.
// Importing InjectionLite once is enough — its module-load constructor starts
// the FSEvents watcher; no explicit `Bundle.main.load*` call needed.
//
// In RELEASE, `import InjectionLite` is excluded, every symbol here compiles
// to a no-op, and the linker dead-strips the package from the binary because
// no Release code references it. Pair with the `-Xlinker -interposable` flag
// in the Debug OTHER_LDFLAGS — Release omits it so injection is physically
// impossible even if the package ever leaked into a shipped build.
//
// Usage:
//     struct CasperFooView: View {
//         @CasperInject private var inject
//         var body: some View {
//             VStack { ... }
//                 .casperHotReload()
//         }
//     }
//
// Delete this file once upstream cmux ships an in-process SwiftUI hot-reload story.

import SwiftUI

#if DEBUG
import Darwin
import InjectionLite
import ObjectiveC

/// InjectionLite's FileWatcher finds the project's build-log directory by
/// observing `.xcactivitylog` write events via FSEvents. The build that
/// produced the running binary happened BEFORE the app launched, and the
/// watcher only backdates by 10_000 FSEvents events. A busy `$HOME` blows
/// past that in seconds, so the watcher never sees the build-log event,
/// `derivedLog` stays nil, and every edit gets "Logs dir not initialised."
///
/// Prime the `HotReloadingBuildLogsDir` UserDefault directly from the running
/// binary's DerivedData path. Bundle layout under DerivedData:
///     <DerivedData>/Build/Products/Debug/cmux DEV.app
/// so walking up four levels gives the DerivedData root, and `/Logs/Build`
/// underneath holds the `.xcactivitylog` files.
func casperPrimeInjectionLogsPath() {
    let bundleURL = Bundle.main.bundleURL
    let derivedDataRoot = bundleURL
        .deletingLastPathComponent() // Debug
        .deletingLastPathComponent() // Products
        .deletingLastPathComponent() // Build
        .deletingLastPathComponent() // <DerivedData>
    let buildLogsDir = derivedDataRoot.appendingPathComponent("Logs/Build")
    guard let entries = try? FileManager.default
            .contentsOfDirectory(at: buildLogsDir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "xcactivitylog" })
            .sorted(by: {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }),
          let newest = entries.first else {
        cmuxDebugLog("casper.hotreload.primeLogs.miss dir=\(buildLogsDir.path)")
        return
    }
    UserDefaults.standard.set(newest.path, forKey: "HotReloadingBuildLogsDir")
    cmuxDebugLog("casper.hotreload.primeLogs.ok log=\(newest.lastPathComponent) count=\(entries.count)")
}

/// Capture InjectionLite's `print()` output (recompile progress, errors,
/// "Watching for source changes under ...") to a file. Without this, stdout
/// for Dock-launched apps is discarded, leaving no way to diagnose silent
/// recompile failures. Path mirrors `/tmp/cmux-debug-<tag>.log`.
func casperCaptureStdoutForHotReload() {
    let path = "/tmp/cmux-casper-stdout.log"
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else {
        cmuxDebugLog("casper.hotreload.stdoutCapture.fail errno=\(errno) path=\(path)")
        return
    }
    let header = "\n=== \(Date()) pid=\(getpid()) cmux-casper-stdout-capture begin ===\n"
    _ = header.withCString { write(fd, $0, strlen($0)) }
    dup2(fd, STDOUT_FILENO)
    dup2(fd, STDERR_FILENO)
    close(fd)
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    cmuxDebugLog("casper.hotreload.stdoutCapture.ok path=\(path)")
}

/// InjectionLite's auto-bootstrap lives in `InjectionBoot.mm` as a `+load`
/// method on an `NSObject` category. Static SPM linking dead-strips category
/// `+load` methods unless `OTHER_LDFLAGS` contains `-ObjC` (which we don't set,
/// to keep Debug/Release flags symmetric). Reach into the Obj-C runtime once
/// and `alloc/init` the `InjectionLite` class ourselves — its `init()` is what
/// `+load` would have called anyway.
private let casperInjectionBootstrap: Void = {
    cmuxDebugLog("casper.hotreload.bootstrap.entry")
    guard let cls = objc_getClass("InjectionLite") as? NSObject.Type else {
        cmuxDebugLog("casper.hotreload.bootstrap.miss reason=objcClassNotFound name=InjectionLite")
        NSLog("⚠️ Casper hot-reload: InjectionLite class not registered with Obj-C runtime")
        return
    }
    cmuxDebugLog("casper.hotreload.bootstrap.instantiating cls=\(cls)")
    let instance = cls.init()
    cmuxDebugLog("casper.hotreload.bootstrap.done instance=\(type(of: instance))")
    // View-independent diagnostic: log every INJECTION_BUNDLE_NOTIFICATION so we
    // can tell "FileWatcher fired" from "no instrumented view was on screen."
    NotificationCenter.default.addObserver(
        forName: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"),
        object: nil,
        queue: nil
    ) { note in
        cmuxDebugLog("casper.hotreload.notification.received object=\(String(describing: note.object))")
    }
}()

/// Force-touches the lazy bootstrap so InjectionLite's FileWatcher starts even
/// if no Casper SwiftUI view (CasperInject / casperHotReload) is on screen yet.
/// Called from `cmuxApp.init()` behind `#if DEBUG`.
func casperHotReloadBootstrap() {
    _ = casperInjectionBootstrap
}

@MainActor
@propertyWrapper
struct CasperInject: DynamicProperty {
    @StateObject private var observer = CasperInjectionObserver()
    var wrappedValue: Void { () }
    init() {}
    func update() { _ = observer.generation }
}

@MainActor
private final class CasperInjectionObserver: ObservableObject {
    @Published var generation: UUID = UUID()
    private var injectionToken: NSObjectProtocol?
    private var casperHMRToken: NSObjectProtocol?

    init() {
        _ = casperInjectionBootstrap
        cmuxDebugLog("casper.hotreload.observer.init")
        // Subscribe to both InjectionLite's notification AND the new casper-hmr
        // daemon's `.casperHMRReloaded`. PR 1 ships both paths in parallel so
        // the same observer wakes up whichever backend is live. PR 3 drops the
        // InjectionLite branch.
        injectionToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            cmuxDebugLog("casper.hotreload.observer.notified source=injectionlite")
            self?.generation = UUID()
        }
        casperHMRToken = NotificationCenter.default.addObserver(
            forName: .casperHMRReloaded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            cmuxDebugLog("casper.hotreload.observer.notified source=casperhmr")
            self?.generation = UUID()
        }
    }

    deinit {
        if let injectionToken { NotificationCenter.default.removeObserver(injectionToken) }
        if let casperHMRToken { NotificationCenter.default.removeObserver(casperHMRToken) }
    }
}

extension View {
    func casperHotReload() -> some View {
        modifier(CasperHotReloadModifier())
    }
}

private struct CasperHotReloadModifier: ViewModifier {
    @StateObject private var observer = CasperInjectionObserver()

    func body(content: Content) -> some View {
        content.id(observer.generation)
    }
}
#else
@MainActor
@propertyWrapper
struct CasperInject: DynamicProperty {
    var wrappedValue: Void { () }
    init() {}
}

extension View {
    @inlinable
    func casperHotReload() -> some View { self }
}

@inlinable
func casperHotReloadBootstrap() {}

@inlinable
func casperCaptureStdoutForHotReload() {}

@inlinable
func casperPrimeInjectionLogsPath() {}
#endif
