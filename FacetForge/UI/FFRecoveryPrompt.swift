import SwiftUI

/// Phase 27's crash-recovery prompt.
///
/// The scrim covers the whole shell and takes every touch, so the viewport
/// beneath it cannot select, orbit or drag while the user has not decided what
/// to do with the recovered edits. The card sits above the scrim; its buttons
/// are the only hit-testable controls. The shell renders this and routes the two
/// decisions; the session owns the offer, the journal and the document.
struct FFRecoveryPromptView: View {
    let offer: FFJournalRecoveryOffer
    let onRestore: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityElement()
                .accessibilityIdentifier("shell.recovery.scrim")
                .accessibilityLabel("Recovery prompt is open")

            VStack(alignment: .leading, spacing: FFSpace.sm) {
                HStack(spacing: FFSpace.xs) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(FFPalette.accent.color)
                        .accessibilityHidden(true)

                    Text("Unsaved edits recovered")
                        .font(FFType.section)
                        .foregroundStyle(FFPalette.textPrimary.color)
                        .accessibilityIdentifier("shell.recovery.title")
                }

                Text(offer.detail)
                    .font(FFType.body)
                    .foregroundStyle(FFPalette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("shell.recovery.detail")

                Text("The saved document is unchanged until you restore.")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: FFSpace.xs) {
                    Spacer(minLength: 0)

                    FFButton(title: "Discard", kind: .destructive, action: onDiscard)
                        .accessibilityIdentifier("shell.recovery.discard")

                    FFButton(
                        title: "Restore",
                        systemImage: "arrow.clockwise",
                        kind: .primary,
                        action: onRestore
                    )
                    .accessibilityIdentifier("shell.recovery.restore")
                }
                .padding(.top, FFSpace.xxs)
            }
            .padding(FFSpace.lg)
            .frame(maxWidth: 520)
            .background(
                FFPalette.raised.color,
                in: RoundedRectangle(cornerRadius: FFRadius.lg, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FFRadius.lg, style: .continuous)
                    .stroke(FFPalette.separator.color, lineWidth: 1)
            }
            .padding(FFSpace.lg)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shell.recovery.prompt")
        }
    }
}
