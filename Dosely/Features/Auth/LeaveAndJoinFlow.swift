import SwiftUI

/// Two-step full-screen flow that lets a supervisor switch families:
/// confirm → leave current circle → join new circle by code → done.
///
/// Presented as a `fullScreenCover` so the dashboard underneath stays
/// hidden while `currentPerson` is briefly stale (the leave deletes
/// the supervisor's `Person` row before the join creates a fresh one).
/// `authService.completeCircleSetup()` is only called once, after the
/// join succeeds, so AuthGate doesn't try to re-route mid-flow.
///
/// Also reachable from the "I created a family by mistake" link on
/// `CircleSetupView` for the case where the user wants to abandon a
/// freshly-created circle. When the user has no circle at all, the
/// confirm step is skipped and the flow opens directly on the join
/// step.
struct LeaveAndJoinFlow: View {
    enum Step {
        case confirmLeave
        case join
    }

    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step
    @State private var leaveError: String?
    @State private var isLeaving = false

    let careCircleRepo: CareCircleRepository

    init(careCircleRepo: CareCircleRepository = CareCircleRepository(),
         initialStep: Step? = nil) {
        self.careCircleRepo = careCircleRepo
        // Use `_step = State(initialValue:)` since the State property
        // doesn't have a default value.
        _step = State(initialValue: initialStep ?? .confirmLeave)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.dsBackground.ignoresSafeArea()

                Group {
                    switch step {
                    case .confirmLeave: confirmLeaveStep
                    case .join:         joinStep
                    }
                }

                if isLeaving {
                    ProgressView().scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.15).ignoresSafeArea())
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(navTitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(isLeaving)
        .task {
            // If the user has no current circle, skip the leave step
            // entirely. Useful for the "I created by mistake" entry on
            // CircleSetupView when there's nothing to abandon.
            if authService.currentPerson?.careCircle == nil {
                step = .join
            }
        }
    }

    private var navTitle: Text {
        switch step {
        case .confirmLeave: return Text("circle.leave.title")
        case .join:         return Text("circle.join.title")
        }
    }

    // MARK: - Step 1: Confirm leave

    private var confirmLeaveStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                Text("circle.leave.title")
                    .dsTitleLarge()
                    .foregroundColor(.dsTextPrimary)

                Text(L("circle.leave.body", currentCircleName as NSString))
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let leaveError {
                    Text(leaveError)
                        .dsBodyRegular()
                        .foregroundColor(.white)
                        .padding(DSSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.dsDanger)
                        .cornerRadius(DSSpacing.rMd)
                }

                VStack(spacing: DSSpacing.md) {
                    Button(action: { Task { await leaveCurrentCircle() } }) {
                        Text("circle.leave.confirm")
                            .dsBodyLarge()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                            .background(Color.dsDanger)
                            .cornerRadius(DSSpacing.rMd)
                    }
                    .accessibilityLabel(Text("circle.leave.confirm"))
                    .disabled(isLeaving)

                    Button(action: { dismiss() }) {
                        Text("common.cancel")
                            .dsBodyLarge()
                            .foregroundColor(.dsPrimary)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                            .overlay(
                                RoundedRectangle(cornerRadius: DSSpacing.rMd)
                                    .stroke(Color.dsPrimary, lineWidth: 1.5)
                            )
                    }
                    .accessibilityLabel(Text("common.cancel"))
                }
            }
            .padding(DSSpacing.lg)
        }
    }

    // MARK: - Step 2: Join

    /// Reuses the existing `JoinCircleView`. Its submit calls
    /// `authService.completeCircleSetup()` which refreshes
    /// `currentPerson` to the fresh supervisor row in the joined
    /// circle. The flow dismisses naturally once AuthGate sees the
    /// new state.
    private var joinStep: some View {
        JoinCircleView(careCircleRepo: careCircleRepo)
    }

    // MARK: - Actions

    private var currentCircleName: String {
        authService.currentPerson?.careCircle?.name ?? ""
    }

    private func leaveCurrentCircle() async {
        guard let id = authService.currentPerson?.id else { return }
        isLeaving = true
        leaveError = nil
        defer { isLeaving = false }

        let result = await careCircleRepo.leaveCircle(supervisorPersonID: id)
        switch result {
        case .success:
            // Deliberately *do not* call completeCircleSetup yet — that
            // would flip needsCircleSetup, prompt AuthGate to re-route,
            // and tear down this fullScreenCover before the user can
            // join a new family. We just advance to the join step.
            step = .join
        case .failure(.lastSupervisor):
            leaveError = L("circle.leave.error.lastsupervisor")
        case .failure(.notMember), .failure(.notFound):
            leaveError = L("circle.leave.error.generic")
        }
    }
}

#if DEBUG
#Preview("LeaveAndJoinFlow") {
    LeaveAndJoinFlow(
        careCircleRepo: CareCircleRepository(stack: CoreDataStack(inMemory: true))
    )
    .environmentObject(AuthService())
}
#endif
