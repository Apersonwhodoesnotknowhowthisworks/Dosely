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

    /// Routes the unlocked user. Supervisors land on the multi-person
    /// dashboard; clients keep using the single-person TodayView (full
    /// device-client mode lands in Prompt 15). While the Person row is
    /// still resolving (Firebase signed in but Core Data fetch in flight)
    /// we show TodayView — it has its own loading state and is harmless
    /// for either role.
    @ViewBuilder
    private var authedRoot: some View {
        if authService.currentPerson?.role == "supervisor" {
            SupervisorDashboardView()
        } else {
            TodayView()
        }
    }
}
