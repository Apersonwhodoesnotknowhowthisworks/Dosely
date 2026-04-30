import SwiftUI

/// "+" flow on the People tab. First step picks the type:
///   - managed_client: name + language → done
///   - device_client:  name + PIN + language → done, then "hand them the phone"
///   - invite supervisor: shows the join code with a Copy button
struct AddPersonFlow: View {
    enum AddType: String, Hashable, CaseIterable {
        case managed = "managed_client"
        case device = "device_client"
        case supervisor = "supervisor"

        var titleKey: String {
            switch self {
            case .managed:    return "supervisor.add.managed.title"
            case .device:     return "supervisor.add.device.title"
            case .supervisor: return "supervisor.add.supervisor.title"
            }
        }

        var blurbKey: String {
            switch self {
            case .managed:    return "supervisor.add.managed.blurb"
            case .device:     return "supervisor.add.device.blurb"
            case .supervisor: return "supervisor.add.supervisor.blurb"
            }
        }

        var icon: String {
            switch self {
            case .managed:    return "heart.fill"
            case .device:     return "lock.shield.fill"
            case .supervisor: return "person.fill.badge.plus"
            }
        }
    }

    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .pickType
    @State private var selectedType: AddType?
    @State private var name: String = ""
    @State private var pin: String = ""
    @State private var language: String = "en"
    @State private var doneMessage: String?
    @State private var joinCode: String?
    @State private var errorMessage: String?

    enum Step: Hashable { case pickType, fillForm, deviceHandoff, supervisorInvite }

    let personRepo: PersonRepository
    let careCircleRepo: CareCircleRepository
    var onAdded: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .pickType:         pickTypeStep
                case .fillForm:         fillFormStep
                case .deviceHandoff:    deviceHandoffStep
                case .supervisorInvite: supervisorInviteStep
                }
            }
            .padding(DSSpacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { dismiss() }
                }
            }
            .alert(L("supervisor.person.error.title"),
                   isPresented: errorBinding) {
                Button(L("common.ok"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task { await loadJoinCodeIfNeeded() }
    }

    private var navTitle: Text {
        switch step {
        case .pickType:         return Text("supervisor.add.title")
        case .fillForm:         return Text(selectedType?.titleKey ?? "supervisor.add.title")
        case .deviceHandoff:    return Text("supervisor.add.device.handoff.title")
        case .supervisorInvite: return Text("supervisor.add.supervisor.title")
        }
    }

    // MARK: - Step 1: pick type

    private var pickTypeStep: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("supervisor.add.choose")
                .dsBodyLarge()
                .foregroundColor(.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(AddType.allCases, id: \.self) { type in
                Button(action: { pickType(type) }) {
                    HStack(spacing: DSSpacing.md) {
                        Image(systemName: type.icon)
                            .font(.title2)
                            .foregroundColor(.dsPrimary)
                            .frame(width: 36)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: DSSpacing.xs) {
                            Text(type.titleKey)
                                .dsBodyLarge()
                                .foregroundColor(.dsTextPrimary)
                            Text(type.blurbKey)
                                .dsBodyRegular()
                                .foregroundColor(.dsTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.dsTextSecondary)
                            .accessibilityHidden(true)
                    }
                    .padding(DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
                }
                .accessibilityLabel(Text(type.titleKey))
            }
        }
    }

    private func pickType(_ type: AddType) {
        selectedType = type
        switch type {
        case .managed, .device:  step = .fillForm
        case .supervisor:        step = .supervisorInvite
        }
    }

    // MARK: - Step 2: fill form (managed / device)

    private var fillFormStep: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("supervisor.person.name").dsCaption().foregroundColor(.dsTextSecondary)
                TextField(L("supervisor.person.name"), text: $name)
                    .dsBodyLarge()
                    .padding(DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsSurface)
                    .cornerRadius(DSSpacing.rMd)
            }

            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text("supervisor.person.language").dsCaption().foregroundColor(.dsTextSecondary)
                Picker(L("supervisor.person.language"), selection: $language) {
                    Text("languagepicker.english").tag("en")
                    Text("languagepicker.punjabi").tag("pa")
                }
                .pickerStyle(.segmented)
            }

            if selectedType == .device {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text("supervisor.add.device.pin").dsCaption().foregroundColor(.dsTextSecondary)
                    TextField(L("supervisor.add.device.pin.placeholder"), text: $pin)
                        .keyboardType(.numberPad)
                        .dsBodyLarge()
                        .padding(DSSpacing.md)
                        .frame(minHeight: DSSpacing.minTapTarget)
                        .background(Color.dsSurface)
                        .cornerRadius(DSSpacing.rMd)
                }
            }

            Button(action: { Task { await createClient() } }) {
                Text("common.save")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .background(canSubmit ? Color.dsPrimary : Color.dsTextSecondary)
                    .cornerRadius(DSSpacing.rMd)
            }
            .disabled(!canSubmit)
            .accessibilityLabel(Text("common.save"))
        }
    }

    private var canSubmit: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if selectedType == .device {
            return pin.count >= 4
        }
        return true
    }

    // MARK: - Step 3a: device handoff

    private var deviceHandoffStep: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 56))
                .foregroundColor(.dsPrimary)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            Text(doneMessage ?? L("supervisor.add.device.handoff.body", name as NSString))
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { dismiss() }) {
                Text("common.done")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel(Text("common.done"))
        }
    }

    // MARK: - Step 3b: supervisor invite

    private var supervisorInviteStep: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("supervisor.add.supervisor.body")
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: DSSpacing.sm) {
                Text(joinCode ?? "—")
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundColor(.dsPrimary)
                    .accessibilityLabel(Text(L("supervisor.add.supervisor.code.a11y",
                                                (joinCode ?? "") as NSString)))
                Button(action: copyJoinCode) {
                    Label(L("supervisor.add.supervisor.copy"), systemImage: "doc.on.doc")
                        .dsBodyRegular()
                        .foregroundColor(.dsPrimary)
                        .padding(.horizontal, DSSpacing.md)
                        .frame(minHeight: DSSpacing.minTapTarget)
                        .overlay(
                            RoundedRectangle(cornerRadius: DSSpacing.rMd)
                                .stroke(Color.dsPrimary, lineWidth: 1.5)
                        )
                }
                .accessibilityLabel(Text("supervisor.add.supervisor.copy"))
            }
            .frame(maxWidth: .infinity)
            .padding(DSSpacing.lg)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rLg)

            Text("supervisor.add.supervisor.footer")
                .dsBodyRegular()
                .foregroundColor(.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: { dismiss() }) {
                Text("common.done")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel(Text("common.done"))
        }
    }

    // MARK: - Actions

    private func createClient() async {
        guard let circle = authService.currentPerson?.careCircle,
              let actorID = authService.currentPerson?.id,
              let type = selectedType else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch type {
            case .managed:
                _ = try await personRepo.createManagedClient(name: trimmedName,
                                                             photoData: nil,
                                                             language: language,
                                                             in: circle,
                                                             actorPersonID: actorID)
                onAdded()
                await MainActor.run { dismiss() }
            case .device:
                _ = try await personRepo.createDeviceClient(name: trimmedName,
                                                            photoData: nil,
                                                            pinPlaintext: pin,
                                                            language: language,
                                                            in: circle,
                                                            actorPersonID: actorID)
                onAdded()
                await MainActor.run {
                    doneMessage = L("supervisor.add.device.handoff.body", trimmedName as NSString)
                    step = .deviceHandoff
                }
            case .supervisor:
                // Handled in supervisorInviteStep — no client to create.
                break
            }
        } catch PersonRepositoryError.permissionDenied {
            await MainActor.run {
                errorMessage = L("supervisor.person.error.notprimary")
            }
        } catch {
            await MainActor.run {
                errorMessage = L("supervisor.person.error.generic")
            }
        }
    }

    private func loadJoinCodeIfNeeded() async {
        guard joinCode == nil,
              let circle = authService.currentPerson?.careCircle else { return }
        await MainActor.run { joinCode = circle.joinCode }
    }

    private func copyJoinCode() {
        guard let code = joinCode else { return }
        UIPasteboard.general.string = code
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
