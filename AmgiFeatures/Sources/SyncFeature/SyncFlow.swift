//
//  SyncFlow.swift
//  SyncFeature
//
//  Created by Vladimir Gusev on 29.08.2026.
//

package import SwiftUI
import AppCore
import AppShared
import Dependencies

/// The whole sync flow behind one modifier: the trigger (published as
/// `EnvironmentValues.startSync` so any toolbar below can fire it), the
/// progress/success toast, the sync sheet, and the collection invalidation
/// each of them implies.
///
/// It lives here rather than in the app root so `SyncCoordinator.state`,
/// `SyncSheet` and the toast controller can stay internal to this module —
/// the root used to drive all three by hand, which is what forced them
/// public.
private struct SyncFlowModifier: ViewModifier {
    let onFinished: () -> Void

    @Dependency(\.syncCoordinator) private var coordinator
    @Dependency(\.collectionStore) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var toast = SyncToastController()
    @State private var showSheet = false
    private var reviewActivity: ReviewActivity { .shared }

    func body(content: Content) -> some View {
        content
            .environment(\.startSync, SyncAction(toast: toast))
            .sheet(isPresented: $showSheet) {
                store.invalidateAll()
                onFinished()
            } content: {
                SyncSheet(isPresented: $showSheet)
                    .presentationDetents([.fraction(0.7), .large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: SyncToastController.needsAttention(coordinator.state)) { _, needs in
                guard needs else { return }
                // An automatic sync that failed (no signal, say) waits for
                // the next one; one that needs a choice made, or a sign-in,
                // asks for it.
                if coordinator.isAutomatic, !coordinator.requiresLogin,
                   case .error = coordinator.state { return }
                showSheet = true
            }
            .onChange(of: coordinator.state) { _, newState in
                if !coordinator.isAutomatic { toast.handle(newState) }
                if case .success = newState { store.invalidateAll() }
            }
            .syncToastOverlay(toast.toast, onDismiss: { toast.dismiss() })
            // Automatic sync: on opening Amgi and every few minutes while
            // it's open, on leaving it, and as each review session ends —
            // never during one.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await autoSync(ifOlderThan: AutoSync.onOpen)
                while !Task.isCancelled {
                    try? await Task.sleep(for: AutoSync.every)
                    guard !Task.isCancelled else { return }
                    await autoSync(ifOlderThan: AutoSync.whileOpen)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                Task { await autoSync(ifOlderThan: AutoSync.onLeaving) }
            }
            .onChange(of: reviewActivity.isReviewing) { _, isReviewing in
                guard !isReviewing else { return }
                Task {
                    // A beat for the screen underneath to settle, and for a
                    // second session opened straight after this one.
                    try? await Task.sleep(for: AutoSync.afterReview)
                    await autoSync(ifOlderThan: 0)
                }
            }
    }

    private func autoSync(ifOlderThan interval: TimeInterval) async {
        guard !reviewActivity.isReviewing else { return }
        await coordinator.autoSync(ifOlderThan: interval)
    }
}

/// When automatic sync runs. The `TimeInterval`s are how recent a sync can
/// be for this one to be skipped.
private enum AutoSync {
    static let onOpen: TimeInterval = 2 * 60
    static let every: Duration = .seconds(5 * 60)
    static let whileOpen: TimeInterval = 4 * 60
    static let onLeaving: TimeInterval = 30
    static let afterReview: Duration = .seconds(3)
}

/// Starts a sync. Installed by `.syncFlow()`; a no-op elsewhere, so a preview
/// or test host renders the toolbar button without a coordinator.
///
/// A struct rather than a closure: SwiftUI cannot compare function values, so
/// the previous `() -> Void` entry made every reader — the tab bar's toolbar
/// — invalidate on each root body evaluation. The one stored property is a
/// class reference, which SwiftUI compares by identity, and `@State` in
/// `SyncFlowModifier` keeps a single instance, so the value is stable.
///
/// Resolution timing note (2026-08-29): `callAsFunction()` resolves
/// `@Dependency(\.syncCoordinator)` at tap time, while `SyncFlowModifier`
/// resolves its own copy when the modifier is constructed. In the shipping
/// app these are the same instance — `bootstrap()` installs one coordinator
/// process-wide — so this never diverges today. It would diverge under a
/// `withDependencies { $0.syncCoordinator = fake }` scope wrapped around view
/// construction, the normal way a preview or test host injects a fake: the
/// modifier's `.onChange` handlers would observe the fake while a tap here
/// would still resolve the real one. Not fixed here — would mean storing the
/// coordinator in `SyncAction` alongside the toast, a real code change.
package struct SyncAction: Equatable {
    private let toast: SyncToastController?

    /// The uninstalled action: calling it does nothing.
    package init() { self.toast = nil }

    init(toast: SyncToastController) { self.toast = toast }

    var isInstalled: Bool { toast != nil }

    @MainActor
    package func callAsFunction() {
        guard let toast else { return }
        @Dependency(\.syncCoordinator) var coordinator
        toast.presentSyncing()
        Task { await coordinator.startSync() }
    }

    package static func == (lhs: SyncAction, rhs: SyncAction) -> Bool {
        lhs.toast === rhs.toast
    }
}

extension EnvironmentValues {
    @Entry package var startSync = SyncAction()
}

extension View {
    /// Attach the sync flow. `onFinished` fires after the sheet is dismissed
    /// so the host can refresh anything not backed by `CollectionStore`.
    package func syncFlow(onFinished: @escaping () -> Void) -> some View {
        modifier(SyncFlowModifier(onFinished: onFinished))
    }
}
