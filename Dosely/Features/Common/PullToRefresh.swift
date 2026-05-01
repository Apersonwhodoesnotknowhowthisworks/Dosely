import SwiftUI

/// Glue between a SwiftUI `.refreshable` gesture and
/// `SyncCoordinator.refresh()`. The refreshable system spinner shows
/// while the closure runs and dismisses on return; this helper takes
/// care of mapping any thrown `SyncRefreshError` into a brief inline
/// banner. A successful refresh — including one with no changes —
/// produces no UI noise.
@MainActor
enum PullToRefresh {
    /// Localized copy for each error case. Kept here so all three tabs
    /// emit the same wording.
    static func errorMessage(for error: SyncRefreshError) -> String {
        switch error {
        case .offline:
            return L("sync.refresh.error.offline")
        case .permissionDenied:
            return L("sync.refresh.error.permissiondenied")
        case .unknown:
            return L("sync.refresh.error.generic")
        }
    }

    /// Runs `SyncCoordinator.shared.refresh()` and writes any thrown
    /// error's user-facing copy into `messageBinding`. The banner
    /// auto-clears after roughly three seconds; the caller's view
    /// reads `messageBinding` to decide whether to render the banner
    /// at all.
    static func perform(coordinator: SyncCoordinator = .shared,
                        messageBinding: Binding<String?>) async {
        do {
            try await coordinator.refresh()
        } catch let error as SyncRefreshError {
            await show(errorMessage(for: error), into: messageBinding)
        } catch {
            await show(L("sync.refresh.error.generic"), into: messageBinding)
        }
    }

    private static func show(_ message: String,
                             into binding: Binding<String?>) async {
        binding.wrappedValue = message
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if binding.wrappedValue == message {
            binding.wrappedValue = nil
        }
    }
}

/// Inline error banner pinned to the top of a tab. Hidden when
/// `message` is nil; auto-dismisses ~3s after `PullToRefresh.perform`
/// sets it.
struct PullToRefreshErrorBanner: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                Text(message)
                    .dsBodyRegular()
                    .foregroundColor(.white)
                    .padding(DSSpacing.md)
                    .frame(maxWidth: .infinity)
                    .background(Color.dsDanger)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityLabel(Text(message))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}

extension View {
    /// Convenience: wraps the `PullToRefreshErrorBanner` modifier with
    /// the standard 3s auto-dismissed top banner.
    func pullToRefreshBanner(message: Binding<String?>) -> some View {
        modifier(PullToRefreshErrorBanner(message: message))
    }
}
