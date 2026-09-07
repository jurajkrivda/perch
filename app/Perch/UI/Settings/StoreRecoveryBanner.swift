import AppKit
import SwiftUI

struct StoreRecoveryBanner: View {
    @Bindable var model: SettingsModel
    @State private var localization = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(localization.text(.storeRecoveryTitle), systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(localization.text(.storeRecoveryMessage))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(localization.text(.storeRecoveryShowFiles)) {
                    if let notice = model.recoveryNotice {
                        NSWorkspace.shared.activateFileViewerSelecting(notice.files)
                    }
                }
                Button(localization.text(.storeRecoveryDismiss)) {
                    model.acknowledgeRecoveryNotice()
                }
                .disabled(model.isAcknowledgingRecovery)
            }
            if let error = model.recoveryErrorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }
}
