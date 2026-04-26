import SwiftUI

/// Shown once per new supervisor account, immediately after their first
/// successful Firebase sign-up. Lets the user pick between creating a
/// brand-new family circle and joining an existing one with a 6-digit
/// code. Both branches end by calling `authService.completeCircleSetup()`,
/// which flips the `needsCircleSetup` gate off and routes AuthGate to
/// the supervisor dashboard.
///
/// One-shot: persistence is keyed on the existence of a `Person` row
/// for this Firebase UID, not on a UserDefaults flag — which means the
/// view is reachable again only if the user signs out completely (and
/// even then, only until a circle is created or joined).
struct CircleSetupView: View {
    @EnvironmentObject var authService: AuthService

    let careCircleRepo: CareCircleRepository
    let personRepo: PersonRepository

    init(careCircleRepo: CareCircleRepository = CareCircleRepository(),
         personRepo: PersonRepository = PersonRepository()) {
        self.careCircleRepo = careCircleRepo
        self.personRepo = personRepo
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.dsBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.xl) {
                        VStack(alignment: .leading, spacing: DSSpacing.sm) {
                            Text("circle.setup.title")
                                .dsTitleLarge()
                                .foregroundColor(.dsTextPrimary)
                            Text("circle.setup.subtitle")
                                .dsBodyLarge()
                                .foregroundColor(.dsTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(spacing: DSSpacing.md) {
                            NavigationLink {
                                CreateCircleView(careCircleRepo: careCircleRepo)
                            } label: {
                                choiceLabel(title: L("circle.setup.create.title"),
                                            blurb: L("circle.setup.create.blurb"),
                                            icon: "house.fill")
                            }
                            .accessibilityLabel(Text("circle.setup.create.title"))

                            NavigationLink {
                                JoinCircleView(careCircleRepo: careCircleRepo)
                            } label: {
                                choiceLabel(title: L("circle.setup.join.title"),
                                            blurb: L("circle.setup.join.blurb"),
                                            icon: "person.2.fill")
                            }
                            .accessibilityLabel(Text("circle.setup.join.title"))
                        }
                    }
                    .padding(DSSpacing.lg)
                }
            }
            .navigationBarHidden(true)
        }
    }

    private func choiceLabel(title: String, blurb: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(title)
                    .dsBodyLarge()
                    .foregroundColor(.white)
                Text(blurb)
                    .dsBodyRegular()
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundColor(.white.opacity(0.8))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpacing.lg)
        .background(Color.dsPrimary)
        .cornerRadius(DSSpacing.rLg)
    }
}

#if DEBUG
#Preview("CircleSetupView") {
    CircleSetupView(
        careCircleRepo: CareCircleRepository(stack: CoreDataStack(inMemory: true)),
        personRepo: PersonRepository(stack: CoreDataStack(inMemory: true))
    )
    .environmentObject(AuthService())
}
#endif
