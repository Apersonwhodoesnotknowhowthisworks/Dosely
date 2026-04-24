import SwiftUI

struct AuthGate: View {
    @StateObject private var authService = AuthService()

    var body: some View {
        Group {
            if authService.currentUser == nil {
                LoginView()
            } else {
                TodayView()
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
