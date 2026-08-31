#if DEBUG
import Foundation
import GlassEQMenuBarUI
import SwiftUI

#Preview("Menu Bar — Active") {
    let profiles = [
        GlassEQMenuBarProfile(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Graphic 31-band"),
        GlassEQMenuBarProfile(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Graphic 10-band"),
        GlassEQMenuBarProfile(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, name: "Parametric")
    ]

    GlassEQMenuBarPanel(
        presentation: GlassEQMenuBarPresentation(
            appName: "GlassEQ",
            version: "v0.9.0 (12)",
            outputTitle: "Output",
            outputName: "MacBook Pro Speakers",
            profileTitle: "Profile",
            profiles: profiles,
            flattenTitle: "Flatten",
            settingsTitle: "Settings",
            quitTitle: "Quit",
            statusTitle: "Active",
            statusTint: .active,
            menuBarStateAccessibilityLabel: "Menu bar state",
            profileAccessibilityHint: "Applies the selected profile",
            flattenAccessibilityHint: "Temporarily sets EQ adjustments to zero while keeping the preamp unchanged",
            processingAccessibilityHint: "Temporarily enables an automatically bypassed output without changing its saved rule"
        ),
        selectedProfileID: .constant(profiles[0].id),
        isFlattened: .constant(false),
        processingEnabled: .constant(true),
        onSettings: {},
        onQuit: {}
    )
    .frame(width: 340)
}
#endif
