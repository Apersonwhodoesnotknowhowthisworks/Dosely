import SwiftUI

/// "I'm setting up for my family" branch. Asks for a family name, then
/// creates a `CareCircle` with the current Firebase user as founding
/// supervisor.
struct CreateCircleView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var familyName: String = ""
    @State private var founderName: String = ""
    @State private var isSubmitting = false
    @FocusState private var focusedField: Field?

    enum Field { case familyName, founderName }

    let careCircleRepo: CareCircleRepository

    init(careCircleRepo: CareCircleRepository = CareCircleRepository()) {
        self.careCircleRepo = careCircleRepo
    }

    var body: some View {
        ZStack {
            Color.dsBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    VStack(alignment: .leading, spacing: DSSpacing.sm) {
                        Text("circle.create.title")
                            .dsTitleLarge()
                            .foregroundColor(.dsTextPrimary)
                        Text("circle.create.subtitle")
                            .dsBodyRegular()
                            .foregroundColor(.dsTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text("circle.create.name.label")
                            .dsCaption()
                            .foregroundColor(.dsTextSecondary)
                        TextField(L("circle.create.name.placeholder"), text: $familyName)
                            .dsBodyLarge()
                            .padding(DSSpacing.md)
                            .frame(minHeight: DSSpacing.minTapTarget)
                            .background(Color.dsSurface)
                            .cornerRadius(DSSpacing.rMd)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .familyName)
                            .onSubmit { focusedField = .founderName }
                    }

                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text("circle.create.founder.label")
                            .dsCaption()
                            .foregroundColor(.dsTextSecondary)
                        TextField(L("circle.create.founder.placeholder"), text: $founderName)
                            .dsBodyLarge()
                            .padding(DSSpacing.md)
                            .frame(minHeight: DSSpacing.minTapTarget)
                            .background(Color.dsSurface)
                            .cornerRadius(DSSpacing.rMd)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .founderName)
                            .onSubmit { Task { await submit() } }
                    }

                    Button(action: { Task { await submit() } }) {
                        Text("circle.create.submit")
                            .dsBodyLarge()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                            .background(canSubmit ? Color.dsPrimary : Color.gray.opacity(0.4))
                            .cornerRadius(DSSpacing.rMd)
                    }
                    .disabled(!canSubmit)
                    .accessibilityLabel(Text("circle.create.submit"))
                }
                .padding(DSSpacing.lg)
            }

            if isSubmitting {
                ProgressView().scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.15).ignoresSafeArea())
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(Text("circle.create.title"))
        .onAppear {
            // Pre-fill founder name from the Firebase profile if we have one.
            if founderName.isEmpty {
                founderName = authService.currentUser?.displayName
                    ?? authService.currentUser?.email
                    ?? ""
            }
            focusedField = .familyName
        }
    }

    private var canSubmit: Bool {
        !familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !founderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isSubmitting
    }

    private func submit() async {
        guard let firebaseUID = authService.currentUser?.uid else { return }
        let trimmedFamily = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFounder = founderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFamily.isEmpty, !trimmedFounder.isEmpty else { return }

        focusedField = nil
        isSubmitting = true
        defer { isSubmitting = false }

        let lang = UserDefaults.standard.string(forKey: "app_language") ?? "en"
        _ = await careCircleRepo.createCareCircle(
            name: trimmedFamily,
            foundingSupervisorFirebaseUID: firebaseUID,
            founderName: trimmedFounder,
            founderLanguage: lang
        )
        await authService.completeCircleSetup()
    }
}
