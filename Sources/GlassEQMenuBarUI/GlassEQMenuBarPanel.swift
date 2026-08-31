import AppKit
import Foundation
import SwiftUI

public struct GlassEQMenuBarProfile: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum GlassEQMenuBarStatusTint: Sendable {
    case active
    case inactive

    fileprivate var color: Color {
        switch self {
        case .active:
            Color(nsColor: .systemGreen)
        case .inactive:
            Color(nsColor: .systemRed)
        }
    }
}

public struct GlassEQMenuBarPresentation: Sendable {
    public let appName: String
    public let version: String
    public let outputTitle: String
    public let outputName: String
    public let profileTitle: String
    public let profiles: [GlassEQMenuBarProfile]
    public let flattenTitle: String
    public let settingsTitle: String
    public let quitTitle: String
    public let statusTitle: String
    public let statusTint: GlassEQMenuBarStatusTint
    public let menuBarStateAccessibilityLabel: String
    public let profileAccessibilityHint: String
    public let flattenAccessibilityHint: String
    public let processingAccessibilityHint: String

    public init(
        appName: String,
        version: String,
        outputTitle: String,
        outputName: String,
        profileTitle: String,
        profiles: [GlassEQMenuBarProfile],
        flattenTitle: String,
        settingsTitle: String,
        quitTitle: String,
        statusTitle: String,
        statusTint: GlassEQMenuBarStatusTint,
        menuBarStateAccessibilityLabel: String,
        profileAccessibilityHint: String,
        flattenAccessibilityHint: String,
        processingAccessibilityHint: String
    ) {
        self.appName = appName
        self.version = version
        self.outputTitle = outputTitle
        self.outputName = outputName
        self.profileTitle = profileTitle
        self.profiles = profiles
        self.flattenTitle = flattenTitle
        self.settingsTitle = settingsTitle
        self.quitTitle = quitTitle
        self.statusTitle = statusTitle
        self.statusTint = statusTint
        self.menuBarStateAccessibilityLabel = menuBarStateAccessibilityLabel
        self.profileAccessibilityHint = profileAccessibilityHint
        self.flattenAccessibilityHint = flattenAccessibilityHint
        self.processingAccessibilityHint = processingAccessibilityHint
    }
}

public struct GlassEQMenuBarPanel: View {
    private let presentation: GlassEQMenuBarPresentation
    @Binding private var selectedProfileID: UUID
    @Binding private var isFlattened: Bool
    @Binding private var processingEnabled: Bool
    private let onSettings: () -> Void
    private let onQuit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlActiveState) private var controlActiveState

    public init(
        presentation: GlassEQMenuBarPresentation,
        selectedProfileID: Binding<UUID>,
        isFlattened: Binding<Bool>,
        processingEnabled: Binding<Bool>,
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.presentation = presentation
        _selectedProfileID = selectedProfileID
        _isFlattened = isFlattened
        _processingEnabled = processingEnabled
        self.onSettings = onSettings
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.profileTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Picker(presentation.profileTitle, selection: $selectedProfileID) {
                        ForEach(presentation.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text(presentation.profileTitle))
                    .accessibilityValue(Text(selectedProfileName))
                    .accessibilityHint(Text(presentation.profileAccessibilityHint))
                    .controlSize(.large)

                    Toggle(presentation.flattenTitle, isOn: $isFlattened)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .accessibilityHint(Text(presentation.flattenAccessibilityHint))

                    Spacer(minLength: 0)
                }
            }
            
            popoverValue(title: presentation.outputTitle, value: presentation.outputName)
            
            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    dismiss()
                    onSettings()
                } label: {
                    Label(presentation.settingsTitle, systemImage: "slider.horizontal.3")
                        .frame(minWidth: 86, minHeight: 28)
                        .contentShape(.rect)
                }
                .controlSize(.large)
                .buttonStyle(.glass)

                Button(role: .destructive, action: onQuit) {
                    Label(presentation.quitTitle, systemImage: "power")
                        .frame(minWidth: 58, minHeight: 28)
                        .contentShape(.rect)
                }
                .controlSize(.large)
                .buttonStyle(.glass)
                
                Spacer()
                
                Text(presentation.statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(presentation.statusTint.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        presentation.statusTint.color.opacity(0.12),
                        in: .capsule
                    )
                    .accessibilityLabel(Text(presentation.menuBarStateAccessibilityLabel))
                    .accessibilityValue(Text(presentation.statusTitle))
            }
        }
        .padding()
        .background { PopoverGlassConfigurator() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.appName)
                    .font(.title3.weight(.semibold))
                Text(presentation.version)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $processingEnabled) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .controlSize(.large)
            .accessibilityHint(Text(presentation.processingAccessibilityHint))
        }
    }

    private var selectedProfileName: String {
        presentation.profiles.first { $0.id == selectedProfileID }?.name ?? ""
    }

    private var popoverControlsAreActive: Bool {
        controlActiveState != .inactive
    }

    private func popoverValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
    }
}

private enum PopoverGlassAppearance {
    /// Opacity applied to the popover's system Liquid Glass backing (NSGlassView).
    /// 1.0 keeps the full system frost; lower values thin it so more of the desktop shows
    /// through. Our content is a sibling of the backing, so it stays fully opaque regardless.
    static let backingAlpha: CGFloat = 0.2
}

private final class PopoverGlassConfiguringView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            return
        }
        let root = window.contentView?.superview ?? window.contentView
        root.map(Self.dimGlassBacking)
    }

    private static func dimGlassBacking(_ view: NSView) {
        if String(describing: type(of: view)) == "NSGlassView" {
            view.alphaValue = PopoverGlassAppearance.backingAlpha
        }
        for subview in view.subviews {
            dimGlassBacking(subview)
        }
    }
}

private struct PopoverGlassConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> PopoverGlassConfiguringView {
        PopoverGlassConfiguringView()
    }

    func updateNSView(_ nsView: PopoverGlassConfiguringView, context: Context) {}
}
