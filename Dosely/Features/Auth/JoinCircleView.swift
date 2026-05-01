import SwiftUI

/// "I'm joining a family" branch. The user enters a 6-digit join code
/// and a display name; on success they're added to the existing
/// CareCircle as a supervisor and routed to the dashboard.
struct JoinCircleView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var code: String = ""
    @State private var displayName: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var codeFocused: Bool
    @FocusState private var nameFocused: Bool

    let careCircleRepo: CareCircleRepository

    init(careCircleRepo: CareCircleRepository = CareCircleRepository()) {
        self.careCircleRepo = careCircleRepo
    }

    var body: some View {
        ZStack {
            Color.dsBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    header
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                    codeField
                    nameField
                    submitButton
                    Spacer(minLength: DSSpacing.xl)
                    backToCreateLink
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
        .navigationTitle(Text("circle.join.title"))
        .onAppear {
            if displayName.isEmpty {
                displayName = authService.currentUser?.displayName
                    ?? authService.currentUser?.email
                    ?? ""
            }
            codeFocused = true
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("circle.join.title")
                .dsTitleLarge()
                .foregroundColor(.dsTextPrimary)
            Text("circle.join.subtitle")
                .dsBodyRegular()
                .foregroundColor(.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .dsBodyRegular()
            .foregroundColor(.white)
            .padding(DSSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dsDanger)
            .cornerRadius(DSSpacing.rMd)
            .accessibilityLabel(Text(text))
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("circle.join.code.label")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
            // Digit boxes overlay the actual TextField. The TextField is
            // a single line — keeps paste support, system numeric keypad,
            // autofill (one-time-code) — while the boxes give the visual
            // affordance the spec asked for.
            ZStack {
                TextField("", text: Binding(
                    get: { code },
                    set: { newValue in
                        let filtered = String(newValue.filter(\.isNumber).prefix(6))
                        code = filtered
                    }
                ))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($codeFocused)
                .opacity(0.001)            // invisible but interactive
                .accessibilityLabel(Text("circle.join.code.label"))

                HStack(spacing: DSSpacing.sm) {
                    ForEach(0..<6, id: \.self) { i in
                        digitBox(for: i)
                    }
                }
                .allowsHitTesting(false)   // taps fall through to the field
            }
            .contentShape(Rectangle())
            .onTapGesture { codeFocused = true }
        }
    }

    private func digitBox(for index: Int) -> some View {
        let chars = Array(code)
        let digit = index < chars.count ? String(chars[index]) : ""
        let isActive = (codeFocused && index == chars.count) ||
                       (codeFocused && chars.count == 6 && index == 5)
        return Text(digit)
            .font(.system(size: 28, weight: .semibold, design: .monospaced))
            .foregroundColor(.dsTextPrimary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rMd)
            .overlay(
                RoundedRectangle(cornerRadius: DSSpacing.rMd)
                    .stroke(isActive ? Color.dsPrimary : Color.dsTextSecondary.opacity(0.25),
                            lineWidth: isActive ? 2 : 1)
            )
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("circle.join.name.label")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
            TextField(L("circle.join.name.placeholder"), text: $displayName)
                .dsBodyLarge()
                .padding(DSSpacing.md)
                .frame(minHeight: DSSpacing.minTapTarget)
                .background(Color.dsSurface)
                .cornerRadius(DSSpacing.rMd)
                .submitLabel(.go)
                .focused($nameFocused)
                .onSubmit { Task { await submit() } }
        }
    }

    private var submitButton: some View {
        Button(action: { Task { await submit() } }) {
            Text("circle.join.submit")
                .dsBodyLarge()
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                .background(canSubmit ? Color.dsPrimary : Color.gray.opacity(0.4))
                .cornerRadius(DSSpacing.rMd)
        }
        .disabled(!canSubmit)
        .accessibilityLabel(Text("circle.join.submit"))
    }

    private var backToCreateLink: some View {
        // The user can also use the system back button to return to
        // CircleSetupView. This quiet link is the spec's "Don't have a
        // code?" affordance and pops back to the same place.
        Button(action: { dismiss() }) {
            Text("circle.join.nocode")
                .dsBodyRegular()
                .foregroundColor(.dsPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.sm)
        }
        .accessibilityLabel(Text("circle.join.nocode"))
    }

    // MARK: - Actions

    private var canSubmit: Bool {
        code.count == 6
        && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isSubmitting
    }

    private func submit() async {
        guard let firebaseUID = authService.currentUser?.uid else { return }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, !trimmedName.isEmpty else { return }

        codeFocused = false
        nameFocused = false
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let lang = UserDefaults.standard.string(forKey: "app_language") ?? "en"
        let result = await careCircleRepo.joinCareCircle(
            code: code,
            asSupervisorWithFirebaseUID: firebaseUID,
            name: trimmedName,
            language: lang
        )

        switch result {
        case .success:
            await authService.completeCircleSetup()
        case .failure(let error):
            errorMessage = friendly(for: error)
            // Clear the code so retry feels fresh.
            code = ""
            codeFocused = true
        }
    }

    private func friendly(for error: CareCircleJoinError) -> String {
        switch error {
        case .codeNotFound:      return L("circle.join.error.notfound")
        case .alreadyMember:     return L("circle.join.error.alreadymember")
        case .invalidName:       return L("circle.join.error.invalidname")
        case .offline:           return L("circle.join.error.offline")
        case .permissionDenied:  return L("circle.join.error.permissiondenied")
        case .unknown:           return L("circle.join.error.unknown")
        }
    }
}
