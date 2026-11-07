import Foundation
import SwiftUI

/// Phase 24's one number for a touch target. Every interactive control keeps
/// at least this square, even when its glyph or label is smaller.
enum FFHitTarget {
    static let minimum: CGFloat = 44
}

// MARK: - Button

struct FFButton: View {
    enum Kind {
        case primary
        case secondary
        case ghost
        case destructive
    }

    let title: String
    var systemImage: String? = nil
    var kind: Kind = .primary
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: FFSpace.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .font(FFType.label)
            .foregroundStyle(foreground)
            .frame(minWidth: FFHitTarget.minimum, minHeight: FFHitTarget.minimum)
            .padding(.horizontal, FFSpace.md)
            .background(background, in: RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
                        .stroke(FFPalette.separator.color, lineWidth: 1)
                }
            }
        }
        .buttonStyle(FFPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        switch kind {
        case .primary: FFPalette.onAccent.color
        case .secondary, .ghost: FFPalette.textPrimary.color
        case .destructive: FFPalette.onGem.color
        }
    }

    private var background: Color {
        switch kind {
        case .primary: FFPalette.accent.color
        case .secondary: FFPalette.raised.color
        case .ghost: .clear
        case .destructive: FFPalette.warning.color
        }
    }
}

struct FFPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Chip

struct FFChip: View {
    let title: String
    var systemImage: String? = nil
    var isSelected = false
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: FFSpace.xxs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .font(FFType.caption)
            .foregroundStyle(isSelected ? FFPalette.onAccent.color : FFPalette.textSecondary.color)
            // A short label such as "Box" or "1-up" must not shrink below a
            // finger-sized target just because its text is narrow.
            .frame(minWidth: FFHitTarget.minimum, minHeight: FFHitTarget.minimum)
            .padding(.horizontal, FFSpace.sm)
            .background(
                isSelected ? FFPalette.accent.color : FFPalette.raised.color,
                in: Capsule()
            )
        }
        .buttonStyle(FFPressStyle())
        .accessibilityIdentifier(accessibilityIdentifier ?? title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Field

struct FFField: View {
    let label: String
    @Binding var value: String
    var unit: String?
    var error: String?
    var placeholder = "0.000"

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.xxs) {
            Text(label)
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textSecondary.color)

            HStack(spacing: FFSpace.xs) {
                TextField(placeholder, text: $value)
                    .font(FFType.mono)
                    .foregroundStyle(FFPalette.textPrimary.color)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.plain)
                    // The field, not only its surrounding capsule, is the
                    // hit target the audit walks. SwiftUI reports a text
                    // field's accessibility frame from its text box, so the
                    // padding is what makes that frame a full 44 pt tall.
                    .padding(.vertical, 13)
                    .frame(minHeight: FFHitTarget.minimum)
                    .contentShape(Rectangle())
                    .accessibilityLabel(label)

                if let unit {
                    Text(unit)
                        .font(FFType.monoSmall)
                        .foregroundStyle(FFPalette.textTertiary.color)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, FFSpace.sm)
            .frame(minHeight: FFHitTarget.minimum)
            .background(FFPalette.field.color, in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                    .stroke(error == nil ? FFPalette.separator.color : FFPalette.warning.color, lineWidth: 1)
            }

            if let error {
                Text(error)
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textWarning.color)
                    .accessibilityLabel("Error: \(error)")
            }
        }
    }
}

// MARK: - Slider

struct FFSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "mm"

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.xxs) {
            HStack {
                Text(label)
                    .font(FFType.label)
                    .foregroundStyle(FFPalette.textPrimary.color)
                Spacer(minLength: FFSpace.xs)
                Text(String(format: "%.2f %@", value, unit))
                    .font(FFType.monoSmall)
                    .foregroundStyle(FFPalette.textAccent.color)
            }

            Slider(value: $value, in: range)
                .tint(FFPalette.accent.color)
                .frame(minHeight: 44)
                .accessibilityLabel(label)
                .accessibilityValue(String(format: "%.2f %@", value, unit))
        }
    }
}

// MARK: - Segmented

struct FFSegmented<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: FFSpace.xxs) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(FFType.caption)
                        .foregroundStyle(
                            selection == option ? FFPalette.onAccent.color : FFPalette.textSecondary.color
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            selection == option ? FFPalette.accent.color : Color.clear,
                            in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(FFSpace.xxs)
        .background(FFPalette.field.color, in: RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
                .stroke(FFPalette.separator.color, lineWidth: 1)
        }
    }
}

// MARK: - Sheet

struct FFSheet<Content: View>: View {
    let title: String
    var subtitle: String?
    private let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.sm) {
            VStack(alignment: .leading, spacing: FFSpace.xxs) {
                Text(title)
                    .font(FFType.section)
                    .foregroundStyle(FFPalette.textPrimary.color)
                if let subtitle {
                    Text(subtitle)
                        .font(FFType.caption)
                        .foregroundStyle(FFPalette.textSecondary.color)
                }
            }

            content
        }
        .padding(FFSpace.md)
        .background(FFPalette.panel.color, in: RoundedRectangle(cornerRadius: FFRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FFRadius.lg, style: .continuous)
                .stroke(FFPalette.separator.color, lineWidth: 1)
        }
        .shadow(
            color: FFElevation.sheet.color,
            radius: FFElevation.sheet.radius,
            x: FFElevation.sheet.x,
            y: FFElevation.sheet.y
        )
    }
}

// MARK: - Panel

struct FFPanel<Content: View>: View {
    let title: String
    var subtitle: String?
    var trailing: String?
    private let content: Content

    init(title: String, subtitle: String? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(FFType.section)
                        .foregroundStyle(FFPalette.textPrimary.color)
                    if let subtitle {
                        Text(subtitle)
                            .font(FFType.caption)
                            .foregroundStyle(FFPalette.textTertiary.color)
                    }
                }
                Spacer(minLength: FFSpace.xs)
                if let trailing {
                    Text(trailing)
                        .font(FFType.monoSmall)
                        .foregroundStyle(FFPalette.textAccent.color)
                }
            }

            content
        }
        .padding(FFSpace.md)
        .background(FFPalette.panel.color, in: RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
                .stroke(FFPalette.separator.color, lineWidth: 1)
        }
    }
}

// MARK: - List row

struct FFListRow: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var trailing: String? = nil
    var isSelected = false

    var body: some View {
        HStack(spacing: FFSpace.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(isSelected ? FFPalette.textAccent.color : FFPalette.textSecondary.color)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FFType.body)
                    .foregroundStyle(FFPalette.textPrimary.color)
                if let subtitle {
                    Text(subtitle)
                        .font(FFType.caption)
                        .foregroundStyle(FFPalette.textTertiary.color)
                }
            }

            Spacer(minLength: FFSpace.xs)

            if let trailing {
                Text(trailing)
                    .font(FFType.monoSmall)
                    .foregroundStyle(FFPalette.textSecondary.color)
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, FFSpace.sm)
        .background(
            isSelected ? FFPalette.raised.color : Color.clear,
            in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Toast

struct FFToast: View {
    enum Kind {
        case info
        case success
        case warning
    }

    let message: String
    var kind: Kind = .info

    var body: some View {
        HStack(spacing: FFSpace.xs) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textPrimary.color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FFSpace.sm)
        .frame(minHeight: 44)
        .background(FFPalette.raised.color, in: RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, FFSpace.xs)
        }
        .shadow(
            color: FFElevation.toast.color,
            radius: FFElevation.toast.radius,
            x: FFElevation.toast.x,
            y: FFElevation.toast.y
        )
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: FFPalette.textAccent.color
        case .success: FFPalette.textSuccess.color
        case .warning: FFPalette.textWarning.color
        }
    }
}

// MARK: - Tooltip

struct FFTooltip: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textPrimary.color)
                .padding(.horizontal, FFSpace.sm)
                .padding(.vertical, FFSpace.xs)
                .background(FFPalette.raised.color, in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                        .stroke(FFPalette.separator.color, lineWidth: 1)
                }

            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 10))
                .foregroundStyle(FFPalette.raised.color)
                .offset(y: -1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toolbar

struct FFToolbarItem: Identifiable {
    let id: String
    let systemImage: String
    let label: String
    var isSelected = false
    var action: () -> Void = {}
}

struct FFToolbar: View {
    let items: [FFToolbarItem]

    var body: some View {
        HStack(spacing: FFSpace.xxs) {
            ForEach(items) { item in
                Button(action: item.action) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(item.isSelected ? FFPalette.onAccent.color : FFPalette.textSecondary.color)
                        .frame(width: 44, height: 44)
                        .background(
                            item.isSelected ? FFPalette.accent.color : Color.clear,
                            in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                        )
                }
                .buttonStyle(FFPressStyle())
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(item.isSelected ? .isSelected : [])
            }

            Spacer(minLength: 0)
        }
        .padding(FFSpace.xxs)
        .background(FFPalette.panel.color, in: RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
                .stroke(FFPalette.separator.color, lineWidth: 1)
        }
    }
}

// MARK: - Empty state

struct FFEmptyState: View {
    let title: String
    let message: String
    var systemImage = "diamond"
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: FFSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(FFPalette.textAccent.color)
                .accessibilityHidden(true)

            Text(title)
                .font(FFType.section)
                .foregroundStyle(FFPalette.textPrimary.color)

            Text(message)
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textTertiary.color)
                .multilineTextAlignment(.center)

            if let actionTitle {
                FFButton(title: actionTitle, kind: .secondary, action: action)
                    .padding(.top, FFSpace.xxs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(FFSpace.lg)
        .background(FFPalette.panel.color, in: RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
                .stroke(FFPalette.separator.color, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
