import SwiftUI

/// "Delete account" with a confirmation. Required by App Store Guideline 5.1.1(v); the server
/// removes the sign-in, the phones and, for a lone owner, the household with its events and files.
struct DeleteAccountButton: View {
    let model: ViewerSessionModel
    @State private var confirming = false

    var body: some View {
        Button("Delete account", role: .destructive) { confirming = true }
            .accessibilityIdentifier("delete-account")
            .disabled(model.isWorking)
            .confirmationDialog(
                "Delete your account?",
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) {
                    Task { await model.deleteAccount() }
                }
            } message: {
                Text("This removes your sign-in and phones. If you're the only member, it also removes your household, events, clips and snapshots. It can't be undone. Premium isn't cancelled: do that in your Apple ID subscriptions.")
            }
    }
}

#Preview("Delete account") {
    List { Section { DeleteAccountButton(model: .demo) } }
}

#Preview("Delete account, Hebrew") {
    List { Section { DeleteAccountButton(model: .demo) } }
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

/// "Download my data": prepares the JSON export, then offers it in the share sheet.
struct ExportDataButton: View {
    let model: ViewerSessionModel
    @State private var file: URL?

    var body: some View {
        if let file {
            ShareLink(item: file) {
                Label("Share my data", systemImage: "square.and.arrow.up")
            }
        } else {
            Button("Download my data", systemImage: "arrow.down.circle") {
                Task { file = await model.exportMyData() }
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier("export-data")
        }
    }
}
