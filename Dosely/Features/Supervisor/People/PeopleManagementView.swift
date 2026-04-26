import SwiftUI

struct PeopleManagementView: View {
    @EnvironmentObject var authService: AuthService
    @State private var people: [Person] = []
    @State private var isLoaded = false
    @State private var showingAdd = false
    @State private var detailPerson: Person?

    let personRepo: PersonRepository
    let careCircleRepo: CareCircleRepository

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    if !isLoaded {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if people.isEmpty {
                        emptyState
                    } else {
                        peopleList
                    }

                    if isLoaded {
                        CircleSettingsSection(
                            personRepo: personRepo,
                            careCircleRepo: careCircleRepo
                        )
                    }
                }
                .padding(DSSpacing.lg)
            }
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle(Text("supervisor.people.title"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showingAdd = true }) {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .frame(width: DSSpacing.minTapTarget, height: DSSpacing.minTapTarget)
                    }
                    .accessibilityLabel(Text("supervisor.people.add"))
                }
            }
        }
        .task(id: authService.currentPerson?.id) {
            await reload()
        }
        .sheet(isPresented: $showingAdd) {
            AddPersonFlow(personRepo: personRepo,
                          careCircleRepo: careCircleRepo) {
                Task { await reload() }
            }
            .environmentObject(authService)
        }
        .sheet(item: $detailPerson) { person in
            PersonDetailView(person: person, personRepo: personRepo) {
                Task { await reload() }
            }
            .environmentObject(authService)
        }
    }

    // MARK: - Sections

    private var peopleList: some View {
        VStack(spacing: DSSpacing.sm) {
            ForEach(people, id: \.id) { person in
                Button(action: { detailPerson = person }) {
                    PersonRow(person: person,
                              isCurrentSupervisor: person.id == authService.currentPerson?.id)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(person.name ?? "") — \(roleLabel(person.role))"))
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: DSSpacing.md) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 48))
                .foregroundColor(.dsPrimary)
                .accessibilityHidden(true)
            Text("supervisor.people.empty.title")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
                .multilineTextAlignment(.center)
            Text("supervisor.people.empty.body")
                .dsBodyRegular()
                .foregroundColor(.dsTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(DSSpacing.xl)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
    }

    // MARK: - Data

    private func reload() async {
        guard let circleID = authService.currentPerson?.careCircle?.id else {
            isLoaded = true
            return
        }
        let fetched = await personRepo.fetchAllPeople(in: circleID)
        // Show the supervisor at the top, then everyone else by name.
        people = fetched.sorted { lhs, rhs in
            if (lhs.role == "supervisor") != (rhs.role == "supervisor") {
                return lhs.role == "supervisor"
            }
            return (lhs.name ?? "") < (rhs.name ?? "")
        }
        isLoaded = true
    }

    private func roleLabel(_ role: String?) -> String {
        switch role {
        case "supervisor":     return L("supervisor.role.supervisor")
        case "device_client":  return L("supervisor.role.deviceclient")
        case "managed_client": return L("supervisor.role.managedclient")
        default:               return ""
        }
    }
}

// MARK: - Row

struct PersonRow: View {
    let person: Person
    let isCurrentSupervisor: Bool

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            avatar
                .frame(width: 48, height: 48)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                HStack(spacing: DSSpacing.xs) {
                    Text(person.name ?? "")
                        .dsBodyLarge()
                        .foregroundColor(.dsTextPrimary)
                    if isCurrentSupervisor {
                        Text("supervisor.people.you")
                            .dsCaption()
                            .foregroundColor(.dsTextSecondary)
                    }
                }
                Text(roleBadge)
                    .dsCaption()
                    .foregroundColor(badgeColor)
                    .padding(.horizontal, DSSpacing.sm)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.15))
                    .cornerRadius(DSSpacing.rSm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .foregroundColor(.dsTextSecondary)
                .accessibilityHidden(true)
        }
        .padding(DSSpacing.md)
        .frame(minHeight: DSSpacing.minTapTarget)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    @ViewBuilder
    private var avatar: some View {
        if let data = person.photoData, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
        } else {
            ZStack {
                Color.dsBackground
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.dsTextSecondary)
            }
        }
    }

    private var roleBadge: String {
        switch person.role {
        case "supervisor":     return L("supervisor.role.supervisor")
        case "device_client":  return L("supervisor.role.deviceclient")
        case "managed_client": return L("supervisor.role.managedclient")
        default:               return ""
        }
    }

    private var badgeColor: Color {
        switch person.role {
        case "supervisor":     return .dsPrimary
        case "device_client":  return .dsSuccess
        case "managed_client": return .dsWarning
        default:               return .dsTextSecondary
        }
    }
}

// MARK: - Circle settings (rename, regenerate join code)

struct CircleSettingsSection: View {
    @EnvironmentObject var authService: AuthService
    @State private var renameText: String = ""
    @State private var showingRenameAlert = false
    @State private var showingRegenAlert = false
    @State private var joinCode: String?
    @State private var circleName: String = ""

    let personRepo: PersonRepository
    let careCircleRepo: CareCircleRepository

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("supervisor.circle.title")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)

            row(title: L("supervisor.circle.name"),
                value: circleName,
                action: { renameText = circleName; showingRenameAlert = true })

            row(title: L("supervisor.circle.joincode"),
                value: joinCode ?? "—",
                actionLabel: L("supervisor.circle.regenerate"),
                action: { showingRegenAlert = true })
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
        .onAppear { reloadCircle() }
        .alert(L("supervisor.circle.rename.title"),
               isPresented: $showingRenameAlert) {
            TextField(L("supervisor.circle.name"), text: $renameText)
            Button(L("common.save")) {
                Task { await rename(to: renameText) }
            }
            Button(L("common.cancel"), role: .cancel) {}
        }
        .alert(L("supervisor.circle.regenerate.title"),
               isPresented: $showingRegenAlert) {
            Button(L("supervisor.circle.regenerate"), role: .destructive) {
                Task { await regenerate() }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text("supervisor.circle.regenerate.body")
        }
    }

    private func row(title: String,
                     value: String,
                     actionLabel: String? = nil,
                     action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(title).dsCaption().foregroundColor(.dsTextSecondary)
                Text(value)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) {
                Text(actionLabel ?? L("common.edit"))
                    .dsBodyRegular()
                    .foregroundColor(.dsPrimary)
                    .padding(.horizontal, DSSpacing.sm)
                    .frame(minHeight: DSSpacing.minTapTarget)
            }
            .accessibilityLabel(Text("\(actionLabel ?? L("common.edit")) — \(title)"))
        }
        .padding(.vertical, DSSpacing.xs)
    }

    private func reloadCircle() {
        guard let circle = authService.currentPerson?.careCircle else { return }
        circleName = circle.name ?? ""
        joinCode = circle.joinCode
    }

    private func rename(to newName: String) async {
        guard let circleID = authService.currentPerson?.careCircle?.id else { return }
        let ok = await careCircleRepo.renameCircle(careCircleID: circleID, newName: newName)
        if ok { await MainActor.run { reloadCircle() } }
    }

    private func regenerate() async {
        guard let circleID = authService.currentPerson?.careCircle?.id else { return }
        let newCode = await careCircleRepo.regenerateJoinCode(careCircleID: circleID)
        await MainActor.run {
            joinCode = newCode ?? joinCode
        }
    }
}
