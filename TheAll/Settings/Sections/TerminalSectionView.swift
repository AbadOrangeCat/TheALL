import SwiftUI

struct TerminalSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    private static let managedKeys = [
        "scrollback-limit",
        "copy-on-select",
        "mouse-hide-while-typing",
        "confirm-close-surface",
    ]

    var body: some View {
        Form {
            BoundStepper(
                settings: settings,
                key: "scrollback-limit",
                defaultValue: 10_000_000,
                range: 0...100_000_000,
                label: L10n.Settings.Terminal.scrollbackLimit
            )

            BoundSegmented(
                settings: settings,
                key: "copy-on-select",
                options: ["false", "true", "clipboard"],
                label: L10n.Settings.Terminal.copyOnSelect
            )

            BoundToggle(
                settings: settings,
                key: "mouse-hide-while-typing",
                defaultValue: false,
                label: L10n.Settings.Terminal.hideMouseWhileTyping
            )

            BoundSegmented(
                settings: settings,
                key: "confirm-close-surface",
                options: ["true", "false", "always"],
                label: L10n.Settings.Terminal.confirmClose
            )

            SettingsResetRow(settings: settings, keys: Self.managedKeys)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
