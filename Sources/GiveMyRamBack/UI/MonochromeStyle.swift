import AppKit
import SwiftUI

struct MonochromePillButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var fullWidth: Bool = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: prominent ? .semibold : .medium))
            .foregroundStyle(
                prominent
                    ? Color(nsColor: .windowBackgroundColor)
                    : Color.primary
            )
            .padding(.horizontal, prominent ? 12 : 9)
            .padding(.vertical, prominent ? 6 : 4)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        prominent
                            ? Color.primary.opacity(configuration.isPressed ? 0.78 : 0.92)
                            : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        Color.primary.opacity(prominent ? 0.0 : 0.16),
                        lineWidth: 0.5
                    )
            )
            .opacity(isEnabled ? 1.0 : 0.38)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
