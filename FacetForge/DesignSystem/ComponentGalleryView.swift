import SwiftUI

struct ComponentGalleryView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var fieldValue = "18.00"
    @State private var invalidValue = "0.05"
    @State private var sliderValue = 2.40
    @State private var unit = "Millimetres"
    @State private var selectedChip = "Rings"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FFSpace.lg) {
                    header

                    section("Buttons", identifier: "buttons") {
                        HStack(spacing: FFSpace.xs) {
                            FFButton(title: "Build ring", systemImage: "sparkles", action: {})
                            FFButton(title: "Preview", kind: .secondary, action: {})
                        }
                        HStack(spacing: FFSpace.xs) {
                            FFButton(title: "Delete", systemImage: "trash", kind: .destructive, action: {})
                            FFButton(title: "Disabled", isEnabled: false, action: {})
                        }
                    }

                    section("Chips", identifier: "chips") {
                        HStack(spacing: FFSpace.xs) {
                            FFChip(title: "Rings", systemImage: "circle", isSelected: true) {
                                selectedChip = "Rings"
                            }
                            FFChip(title: "Stones", systemImage: "diamond") {
                                selectedChip = "Stones"
                            }
                            FFChip(title: "Settings", systemImage: "gearshape") {
                                selectedChip = "Settings"
                            }
                        }
                        Text("Selected: \(selectedChip)")
                            .font(FFType.caption)
                            .foregroundStyle(FFPalette.textTertiary.color)
                    }

                    section("Fields", identifier: "fields") {
                        VStack(spacing: FFSpace.sm) {
                            FFField(label: "Band width", value: $fieldValue, unit: "mm")
                            FFField(
                                label: "Wall thickness",
                                value: $invalidValue,
                                unit: "mm",
                                error: "Below the 0.15 mm minimum for this alloy"
                            )
                        }
                    }

                    section("Slider", identifier: "slider") {
                        FFSlider(label: "Band thickness", value: $sliderValue, range: 1.2...4.0, unit: "mm")
                    }

                    section("Segmented", identifier: "segmented") {
                        FFSegmented(options: ["Millimetres", "Inches", "Ring size"], title: { $0 }, selection: $unit)
                    }

                    section("Sheet", identifier: "sheet") {
                        FFSheet(title: "Manufacturing", subtitle: "Casting tree A · 18k yellow gold") {
                            Text("3 solids · 2 stones · watertight")
                                .font(FFType.caption)
                                .foregroundStyle(FFPalette.textSecondary.color)
                        }
                    }

                    section("Panel", identifier: "panel") {
                        FFPanel(title: "Ring builder", subtitle: "Comfort fit", trailing: "2.4 g") {
                            Text("Rail 18.00 mm · head four-prong · seat 1.20 mm")
                                .font(FFType.monoSmall)
                                .foregroundStyle(FFPalette.textSecondary.color)
                        }
                    }

                    section("List rows", identifier: "list") {
                        VStack(spacing: FFSpace.xxs) {
                            FFListRow(
                                title: "Solitaire",
                                subtitle: "Ring · 1 stone",
                                systemImage: "circle",
                                trailing: "18.0 mm",
                                isSelected: true
                            )
                            FFListRow(
                                title: "Prong",
                                subtitle: "Head · four prong",
                                systemImage: "diamond",
                                trailing: "1.2 mm"
                            )
                        }
                    }

                    section("Toasts", identifier: "toast") {
                        VStack(spacing: FFSpace.xs) {
                            FFToast(message: "Document saved", kind: .success)
                            FFToast(message: "Wall below vendor minimum", kind: .warning)
                            FFToast(message: "12 stones counted", kind: .info)
                        }
                    }

                    section("Tooltip", identifier: "tooltip") {
                        FFTooltip(text: "Seat depth is measured from the girdle plane.")
                    }

                    section("Toolbar", identifier: "toolbar") {
                        FFToolbar(items: [
                            FFToolbarItem(id: "select", systemImage: "cursorarrow", label: "Select", isSelected: true),
                            FFToolbarItem(id: "orbit", systemImage: "rotate.3d", label: "Orbit"),
                            FFToolbarItem(id: "measure", systemImage: "ruler", label: "Measure"),
                            FFToolbarItem(id: "render", systemImage: "camera", label: "Render"),
                        ])
                    }

                    section("Empty state", identifier: "empty") {
                        FFEmptyState(
                            title: "No document open",
                            message: "Create a ring, a band or a pendant to begin.",
                            actionTitle: "New document"
                        )
                    }
                }
                .padding(FFSpace.lg)
            }
            .background(FFPalette.canvas.color)
            .navigationTitle("Component gallery")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: FFSpace.sm) {
            VStack(alignment: .leading, spacing: FFSpace.xs) {
                Text("Component gallery")
                    .font(FFType.display)
                    .foregroundStyle(FFPalette.textPrimary.color)
                    .accessibilityIdentifier("gallery.title")

                Text("\(FFComponentCatalog.names.count) primitives · dark-first · AA text contrast")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textSecondary.color)
            }

            Spacer(minLength: 0)

            // A navigation-bar Done button reports a 36 pt tall accessibility
            // frame on iOS, below Phase 24's 44 pt minimum. The dismissal
            // lives in the header instead, where the design system owns the
            // size: FFButton is at least 44×44 by construction.
            FFButton(title: "Done", kind: .secondary) { dismiss() }
                .accessibilityIdentifier("gallery.done")
        }
    }

    private func section<Content: View>(
        _ title: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.sm) {
            Text(title.uppercased())
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textTertiary.color)
                .accessibilityIdentifier("gallery.section.\(identifier)")

            content()
        }
    }
}

// MARK: - Snapshot fixtures

struct FFSnapshotCase: Identifiable {
    let id: String
    let size: CGSize
    let view: AnyView
}

enum FFComponentFixtures {
    static var cases: [FFSnapshotCase] {
        [
            FFSnapshotCase(
                id: "button",
                size: CGSize(width: 340, height: 72),
                view: card {
                    HStack(spacing: FFSpace.xs) {
                        FFButton(title: "Build ring", systemImage: "sparkles", action: {})
                        FFButton(title: "Preview", kind: .secondary, action: {})
                    }
                }
            ),
            FFSnapshotCase(
                id: "chip",
                size: CGSize(width: 340, height: 72),
                view: card {
                    HStack(spacing: FFSpace.xs) {
                        FFChip(title: "Rings", systemImage: "circle", isSelected: true) {}
                        FFChip(title: "Stones", systemImage: "diamond") {}
                    }
                }
            ),
            FFSnapshotCase(
                id: "field",
                size: CGSize(width: 340, height: 92),
                view: card {
                    FFField(label: "Band width", value: .constant("18.00"), unit: "mm")
                }
            ),
            FFSnapshotCase(
                id: "slider",
                size: CGSize(width: 340, height: 92),
                view: card {
                    FFSlider(label: "Band thickness", value: .constant(2.40), range: 1.2...4.0, unit: "mm")
                }
            ),
            FFSnapshotCase(
                id: "segmented",
                size: CGSize(width: 340, height: 72),
                view: card {
                    FFSegmented(options: ["mm", "in", "size"], title: { $0 }, selection: .constant("mm"))
                }
            ),
            FFSnapshotCase(
                id: "sheet",
                size: CGSize(width: 340, height: 168),
                view: card {
                    FFSheet(title: "Manufacturing", subtitle: "Casting tree A") {
                        Text("3 solids · 2 stones · watertight")
                            .font(FFType.caption)
                            .foregroundStyle(FFPalette.textSecondary.color)
                    }
                }
            ),
            FFSnapshotCase(
                id: "panel",
                size: CGSize(width: 340, height: 168),
                view: card {
                    FFPanel(title: "Ring builder", subtitle: "Comfort fit", trailing: "2.4 g") {
                        Text("Rail 18.00 mm · four-prong head")
                            .font(FFType.monoSmall)
                            .foregroundStyle(FFPalette.textSecondary.color)
                    }
                }
            ),
            FFSnapshotCase(
                id: "list-row",
                size: CGSize(width: 340, height: 96),
                view: card {
                    VStack(spacing: FFSpace.xxs) {
                        FFListRow(
                            title: "Solitaire",
                            subtitle: "Ring · 1 stone",
                            systemImage: "circle",
                            trailing: "18.0 mm",
                            isSelected: true
                        )
                        FFListRow(title: "Prong", subtitle: "Head · four prong", systemImage: "diamond")
                    }
                }
            ),
            FFSnapshotCase(
                id: "toast",
                size: CGSize(width: 340, height: 72),
                view: card {
                    FFToast(message: "Document saved", kind: .success)
                }
            ),
            FFSnapshotCase(
                id: "tooltip",
                size: CGSize(width: 340, height: 80),
                view: card {
                    FFTooltip(text: "Seat depth from the girdle plane.")
                }
            ),
            FFSnapshotCase(
                id: "toolbar",
                size: CGSize(width: 340, height: 72),
                view: card {
                    FFToolbar(items: [
                        FFToolbarItem(id: "select", systemImage: "cursorarrow", label: "Select", isSelected: true),
                        FFToolbarItem(id: "orbit", systemImage: "rotate.3d", label: "Orbit"),
                        FFToolbarItem(id: "measure", systemImage: "ruler", label: "Measure"),
                    ])
                }
            ),
            FFSnapshotCase(
                id: "empty-state",
                size: CGSize(width: 340, height: 236),
                view: card {
                    FFEmptyState(
                        title: "No document open",
                        message: "Create a ring, a band or a pendant to begin.",
                        actionTitle: "New document"
                    )
                }
            ),
        ]
    }

    private static func card<Content: View>(@ViewBuilder content: () -> Content) -> AnyView {
        AnyView(
            ZStack {
                FFPalette.canvas.color
                content()
                    .padding(FFSpace.sm)
            }
        )
    }
}
