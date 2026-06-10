import SwiftUI

struct AuthGate: View {
    @StateObject private var authService = AuthService()

    var body: some View {
        Group {
            // The lock is local; it gates AuthGate even when Firebase still
            // has a live session. See AuthService.isLocallyLocked.
            if authService.currentUser == nil || authService.isLocallyLocked {
                LoginView()
            } else {
                authedRoot
                    // Order matters: the .alert is set up before the
                    // .fullScreenCover so SwiftUI presents it first. The
                    // alert's button actions advance to `needsDisclaimer`
                    // only after dismissal, so the two never compete.
                    .alert(
                        Text("auth.signup.faceid.title"),
                        isPresented: $authService.needsBiometricEnrollmentPrompt
                    ) {
                        Button(L("common.yes")) {
                            authService.completeBiometricEnrollmentPrompt(enableBiometric: true)
                        }
                        Button(L("common.notnow"), role: .cancel) {
                            authService.completeBiometricEnrollmentPrompt(enableBiometric: false)
                        }
                    } message: {
                        Text("auth.signup.faceid.message")
                    }
                    .fullScreenCover(isPresented: $authService.needsDisclaimer) {
                        MedicalDisclaimerView {
                            UserDefaults.standard.set(true, forKey: "disclaimer_accepted")
                            authService.needsDisclaimer = false
                        }
                    }
            }
        }
        .environmentObject(authService)
    }

    /// Routes the unlocked user. New supervisor accounts land on
    /// `CircleSetupView` until they create or join a circle. Existing
    /// supervisors get the multi-person dashboard; clients keep using
    /// the single-person TodayView. Routing keys on `actorPerson` — the
    /// act-as overlay — so a primary supervisor who switched into a family
    /// member's view lands on that member's TodayView, and switching back
    /// re-routes to the dashboard. Both transitions are reactive:
    /// `actingPersonID` is @Published on the coordinator and republishes
    /// through `authService`. The biometric / disclaimer overlays are
    /// layered above whichever underlying view is active.
    @ViewBuilder
    private var authedRoot: some View {
        Group {
            switch Self.route(needsCircleSetup: authService.needsCircleSetup,
                              actorRole: authService.actorPerson?.role) {
            case .circleSetup:
                CircleSetupView()
            case .supervisorDashboard:
                SupervisorDashboardView()
            case .todayView:
                TodayView()
            }
        }
        // The act-as banner is chrome, not content: it overlays every routed
        // view (D7) and never scrolls away (D10).
        .actAsBanner()
    }

    /// Pure routing rule, static so the tests can pin every branch without
    /// hosting the view (the 2026-05-28 walker-triage convention).
    enum Route: Equatable {
        case circleSetup, supervisorDashboard, todayView
    }

    static func route(needsCircleSetup: Bool, actorRole: String?) -> Route {
        if needsCircleSetup { return .circleSetup }
        return Roles.isAnySupervisor(actorRole) ? .supervisorDashboard : .todayView
    }
}
