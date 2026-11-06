import SwiftUI

/// A pill-shaped button for destructive actions — delete, remove, reset, discard.
///
/// Renders as a tinted-red capsule with an SF Symbol and a title, full-width so it
/// sits naturally at the bottom of a form or sheet. The title and icon are
/// configurable; the icon defaults to `trash`.
///
/// ```swift
/// DestructiveButton("Delete Meal") { deleteMeal() }
/// DestructiveButton("Remove Goal", systemImage: "trash") { removeGoal() }
/// ```
public struct DestructiveButton: View {

    private let title: String
    private let systemImage: String
    private let action: () -> Void

    /// - Parameters:
    ///   - title: The button label, e.g. "Delete Meal".
    ///   - systemImage: SF Symbol name shown before the title. Defaults to `trash`.
    ///   - action: Invoked when the button is tapped.
    public init(
        _ title: String,
        systemImage: String = "trash",
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Capsule()
                    .fill(Color.red.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.red.opacity(0.4), lineWidth: 1.5)
            )
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 16) {
        DestructiveButton("Delete Meal") {}
        DestructiveButton("Remove Goal") {}
        DestructiveButton("Reset", systemImage: "arrow.counterclockwise") {}
    }
    .padding()
}
