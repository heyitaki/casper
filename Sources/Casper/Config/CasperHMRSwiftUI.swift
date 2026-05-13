// CASPER: SwiftUI hot-reload glue for the casper-hmr daemon. A view that
// declares `@CasperInject` or applies `.casperHMRReload()` subscribes to
// `.casperHMRReloaded`; CasperHMRDaemon posts that notification after every
// successful dlopen swap, and the modifier bumps a per-view UUID id so
// SwiftUI invalidates and re-evaluates the body with the freshly loaded code.
//
// Usage:
//     struct CasperFooView: View {
//         @CasperInject private var inject
//         var body: some View {
//             VStack { ... }
//                 .casperHMRReload()
//         }
//     }
//
// Delete this file once upstream cmux ships an in-process SwiftUI hot-reload
// story (paired with deleting Sources/Casper/HMR/).

import SwiftUI

#if DEBUG

@MainActor
@propertyWrapper
struct CasperInject: DynamicProperty {
    @StateObject private var observer = CasperHMRObserver()
    var wrappedValue: Void { () }
    init() {}
    // Read generation to register it as a SwiftUI dependency so the enclosing
    // view's body re-evaluates when the daemon posts a swap notification.
    func update() { _ = observer.generation }
}

@MainActor
private final class CasperHMRObserver: ObservableObject {
    @Published var generation: UUID = UUID()
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: .casperHMRReloaded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.generation = UUID()
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

extension View {
    func casperHMRReload() -> some View {
        modifier(CasperHMRReloadModifier())
    }
}

private struct CasperHMRReloadModifier: ViewModifier {
    @StateObject private var observer = CasperHMRObserver()

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
    func casperHMRReload() -> some View { self }
}

#endif
