import SwiftUI

/// Horizontal scroll of circular avatars. The first avatar is "All" and
/// represents the combined-circle view. Each subsequent avatar is one
/// client (managed or device). The selected avatar gets a primary-color
/// ring; the rest are unringed.
struct PersonSelector: View {
    let clients: [Person]
    /// `nil` means "All".
    @Binding var activePersonID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpacing.md) {
                allAvatar
                ForEach(clients, id: \.id) { person in
                    PersonAvatar(
                        name: person.name ?? "",
                        photoData: person.photoData,
                        isSelected: activePersonID == person.id,
                        accessibilityLabel: L("supervisor.selector.person.a11y", (person.name ?? "") as NSString)
                    ) {
                        activePersonID = person.id
                    }
                }
            }
            .padding(.horizontal, DSSpacing.lg)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("supervisor.selector.title"))
    }

    private var allAvatar: some View {
        PersonAvatar(
            name: L("supervisor.selector.all"),
            photoData: nil,
            isSelected: activePersonID == nil,
            systemImageFallback: "person.3.fill",
            accessibilityLabel: L("supervisor.selector.all.a11y")
        ) {
            activePersonID = nil
        }
    }
}

struct PersonAvatar: View {
    let name: String
    let photoData: Data?
    let isSelected: Bool
    var systemImageFallback: String = "person.crop.circle.fill"
    let accessibilityLabel: String
    let action: () -> Void

    private let avatarSize: CGFloat = 64

    var body: some View {
        Button(action: action) {
            VStack(spacing: DSSpacing.xs) {
                avatarImage
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.dsPrimary : Color.clear, lineWidth: 3)
                    )
                Text(displayName)
                    .dsCaption()
                    .foregroundColor(isSelected ? .dsPrimary : .dsTextSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: avatarSize + DSSpacing.sm)
            }
            .frame(minWidth: DSSpacing.minTapTarget)
        }
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let data = photoData, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.dsSurface
                Image(systemName: systemImageFallback)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundColor(.dsTextSecondary)
            }
        }
    }

    private var displayName: String {
        // Show first name only so the labels stay legible at avatar width.
        name.components(separatedBy: " ").first ?? name
    }
}

#if DEBUG
#Preview("PersonSelector") {
    StatefulPreviewWrapper<UUID?>(nil) { binding in
        PersonSelector(clients: [], activePersonID: binding)
            .padding()
            .background(Color.dsBackground)
    }
}

private struct StatefulPreviewWrapper<Value>: View {
    @State private var value: Value
    let content: (Binding<Value>) -> AnyView

    init<C: View>(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> C) {
        _value = State(initialValue: initial)
        self.content = { AnyView(content($0)) }
    }

    var body: some View { content($value) }
}
#endif
