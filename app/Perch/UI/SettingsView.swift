import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var model = SettingsModel()
    @State private var localization = LocalizationManager.shared

    var body: some View {
        TabView {
            GeneralSettingsTab(model: model)
                .tabItem { Label(localization.text(.generalTabTitle), systemImage: "gearshape") }

            LayoutsSettingsTab(model: model)
                .tabItem { Label(localization.text(.layoutsTabTitle), systemImage: "rectangle.on.rectangle") }

            AboutSettingsTab(model: model)
                .tabItem { Label(localization.text(.aboutTabTitle), systemImage: "info.circle") }
        }
        .safeAreaInset(edge: .top) {
            if model.recoveryNotice != nil {
                StoreRecoveryBanner(model: model)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .task {
            await model.bootstrap()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccessibilityStatus()
            model.refreshLaunchAtLoginStatus()
            model.refreshAutomaticUpdateChecks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .perchDocumentDidChange)) { _ in
            model.scheduleDocumentRefresh()
        }
    }
}

#Preview {
    SettingsView()
}
