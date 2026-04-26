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
                TodayView()
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
}
