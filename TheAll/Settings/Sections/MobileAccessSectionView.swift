import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

struct MobileAccessSectionView: View {
    let theme: AppTheme
    @State private var controller: MobileAccessController
    @State private var showsCertificateSetup = false
    @State private var exportError: String?
    @State private var sharedWorkspace = ""
    @State private var writable = true
    @Environment(\.locale) private var locale
    private func text(_ key: String) -> String { L10n.string("mobile." + key) }

    init(theme: AppTheme, controller: MobileAccessController = TheAllRuntime.shared.mobile) {
        self.theme = theme
        _controller = State(initialValue: controller)
    }

    var body: some View {
        let _ = locale
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(text("title")).font(.title2.bold())
                Text(text("detail")).foregroundStyle(Color(theme.textSecondary))
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        controller.connectPhone(access: selectedAccess)
                    } label: {
                        Label(text(controller.isPreparingLANInvitation ? "starting" : "lan.quickPair"), systemImage: "qrcode")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isPreparingLANInvitation)
                    Text(text("lan.quickHelp")).foregroundStyle(Color(theme.textSecondary))
                    Text(text("lan.quickPrivacy")).font(.caption).foregroundStyle(Color(theme.textSecondary))
                    if let error = controller.lanError { Text(error).foregroundStyle(Color(theme.accent)) }
                    if let error = controller.error { Text(error).foregroundStyle(Color(theme.accent)) }
                }
                if let link = controller.pairingURL, let entry = controller.pairingEntry {
                    Divider()
                    Text(text("pair." + entry.rawValue)).font(.headline)
                    HStack(alignment: .top, spacing: 20) {
                        if let image = qrCode(link) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                                .accessibilityLabel(text("qr"))
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text(text("pairHelp"))
                            Text(accessTitle(controller.invitationAccess)).font(.callout.bold())
                            if entry == .lan && controller.lanMode == .encrypted { Text(text("lan.pairHelp")).foregroundStyle(Color(theme.textSecondary)) }
                            if entry == .preview { Text(text("localOnly")).foregroundStyle(Color(theme.accent)) }
                            HStack {
                                Button(text("copy")) { copy(link) }
                                Button(text("lan.newCode")) { invite(entry) }
                            }
                            if let expiry = controller.pairingExpires {
                                Text(expiry, style: .relative).font(.caption).foregroundStyle(Color(theme.textSecondary))
                            }
                        }
                    }
                }
                if let device = controller.pairedDevice {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(text("share.paired"), systemImage: "checkmark.circle.fill").font(.headline)
                        Text(device.name + " · " + accessTitle(device.access))
                        Text(text(controller.onlineDeviceIDs.contains(device.id) ? "share.online" : "share.offline"))
                            .font(.callout)
                    }.foregroundStyle(Color(theme.accent))
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(theme.accentMuted), in: RoundedRectangle(cornerRadius: 12))
                }
                Divider()
                advancedSection
                Divider()
                Text(text("devices")).font(.headline)
                if controller.devices.isEmpty { Text(text("noDevices")).foregroundStyle(Color(theme.textSecondary)) }
                ForEach(controller.devices) { device in
                    HStack {
                        Image(systemName: "iphone")
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(accessTitle(device.access)).font(.caption).foregroundStyle(Color(theme.textSecondary))
                            Text(text(device.expiresAt <= Date() ? "share.expired" : controller.onlineDeviceIDs.contains(device.id) ? "share.online" : "share.offline"))
                                .font(.caption).foregroundStyle(Color(theme.textSecondary))
                            if let origin = device.origin { Text(origin).font(.caption).foregroundStyle(Color(theme.textSecondary)) }
                            Text(device.expiresAt, style: .date).font(.caption).foregroundStyle(Color(theme.textSecondary))
                        }
                        Spacer()
                        Button(text("revoke")) { controller.revoke(device.id) }
                    }
                }
                Text(text("availability")).font(.callout).foregroundStyle(Color(theme.textSecondary))
            }
            .foregroundStyle(Color(theme.textPrimary))
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(theme.canvas))
        .onAppear { controller.prepareIdentity(); controller.refreshLANAddresses() }
    }

    private var advancedSection: some View {
        DisclosureGroup(text("advanced")) {
            VStack(alignment: .leading, spacing: 20) {
                Toggle(text("enable"), isOn: Binding(get: { controller.isEnabled }, set: {
                    if $0 { controller.enable() } else { controller.disable() }
                }))
                Text(text("modesHelp")).font(.callout).foregroundStyle(Color(theme.textSecondary))
                Text(text("share.title")).font(.headline)
                Picker(text("share.scope"), selection: $sharedWorkspace) {
                    Text(text("share.all")).tag("")
                    ForEach(controller.shareWorkspaces) { workspace in
                        Text(workspace.name).tag(workspace.id.uuidString)
                    }
                    if !sharedWorkspace.isEmpty, !controller.shareWorkspaces.contains(where: { $0.id.uuidString == sharedWorkspace }) {
                        Text(text("share.unavailable")).tag(sharedWorkspace)
                    }
                }
                Picker(text("share.permission"), selection: $writable) {
                    Text(text("share.readOnly")).tag(false)
                    Text(text("share.writable")).tag(true)
                }.pickerStyle(.segmented)
                Text(text("share.help")).font(.callout).foregroundStyle(Color(theme.textSecondary))
                Divider()
                lanSection
                Divider()
                relaySection
                Divider()
                DisclosureGroup(text("preview")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(text("localOnly")).font(.callout).foregroundStyle(Color(theme.textSecondary))
                        Button(text("pair.preview")) { invite(.preview) }
                            .disabled(!controller.canPair(via: .preview))
                        Button(text("preview")) {
                            if let url = URL(string: controller.localURL) { NSWorkspace.shared.open(url) }
                        }.disabled(!controller.isListening)
                    }.padding(.top, 10)
                }
            }.padding(.top, 12)
        }
    }

    private var lanSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(text("lan.enable"), isOn: Binding(get: { controller.useLAN }, set: controller.setLANEnabled))
                .font(.headline)
            Text(text("lan.help")).foregroundStyle(Color(theme.textSecondary))
            if controller.useLAN {
                Picker(text("lan.mode"), selection: Binding(get: { controller.lanMode }, set: controller.setLANMode)) {
                    Text(text("lan.mode.quick")).tag(MobileAccessController.LANMode.quick)
                    Text(text("lan.mode.encrypted")).tag(MobileAccessController.LANMode.encrypted)
                }
                HStack {
                    Picker(text("lan.address"), selection: Binding(get: { controller.lanAddress }, set: controller.selectLANAddress)) {
                        if !controller.lanAddresses.contains(where: { $0.address == controller.lanAddress }) {
                            Text(controller.lanAddress.isEmpty ? text("lan.noAddress") : controller.lanAddress + " · " + text("lan.offline"))
                                .tag(controller.lanAddress)
                        }
                        ForEach(controller.lanAddresses) { address in Text(address.title).tag(address.address) }
                    }
                    Button(text("lan.refresh")) { controller.refreshLANAddresses() }
                }
                if controller.isEnabled {
                    Label(text(controller.isLANListening ? (controller.lanMode == .quick ? "lan.quickOnline" : "lan.online") : "lan.offline"), systemImage: controller.isLANListening ? "checkmark.circle.fill" : "wifi.slash")
                        .foregroundStyle(Color(theme.accent))
                }
                if let error = controller.lanError { Text(error).foregroundStyle(Color(theme.accent)) }
                if let url = controller.lanURL { Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                if controller.lanMode == .encrypted {
                    DisclosureGroup(text("lan.setup"), isExpanded: $showsCertificateSetup) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(text("lan.certificateHelp"))
                            HStack {
                                Button(text("lan.exportIOS")) { exportCertificate(iOS: true) }
                                Button(text("lan.exportAndroid")) { exportCertificate(iOS: false) }
                            }.disabled(!controller.canExportLANCertificate)
                            Text(text("lan.iosSteps")).font(.callout)
                            Text(text("lan.androidSteps")).font(.callout)
                            Text(text("lan.certificateScope")).font(.callout).foregroundStyle(Color(theme.textSecondary))
                            if !controller.lanCertificateName.isEmpty {
                                Text(controller.lanCertificateName).font(.callout.bold()).textSelection(.enabled)
                                Text("SHA-256: " + controller.lanCertificateFingerprint)
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                            if let exportError { Text(exportError).foregroundStyle(Color(theme.accent)) }
                        }.padding(.top, 10)
                    }
                }
                Button(text("pair.lan")) { invite(.lan) }
                    .buttonStyle(.borderedProminent).disabled(!controller.canPair(via: .lan))
                Text(text("lan.addressChanges")).font(.callout).foregroundStyle(Color(theme.textSecondary))
            }
        }
    }

    private var relaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(text("useRelay"), isOn: Binding(get: { controller.useRelay }, set: controller.setRelayEnabled))
                .font(.headline)
            Text(text("relayHelp")).foregroundStyle(Color(theme.textSecondary))
            TextField("https://computer.example.com", text: $controller.publicURL)
                .textFieldStyle(.roundedBorder).disabled(controller.isEnabled)
            Text(text("addressHelp")).font(.callout).foregroundStyle(Color(theme.textSecondary))
            if controller.useRelay {
                if controller.isEnabled, !controller.publicURL.isEmpty {
                    Text(text(controller.relayConnected ? "relayOnline" : "relayConnecting"))
                        .foregroundStyle(Color(theme.accent))
                }
                if let error = controller.relayError { Text(error).foregroundStyle(Color(theme.accent)) }
                Button(text("pair.relay")) { invite(.relay) }
                    .buttonStyle(.borderedProminent).disabled(!controller.canPair(via: .relay))
                DisclosureGroup(text("connectTitle")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(text("connectHelp")).foregroundStyle(Color(theme.textSecondary))
                        Text(controller.publicKey).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Button(text("copyIdentity")) { copy(controller.publicKey) }.disabled(controller.publicKey.isEmpty)
                        Text(text("connectDomainHelp")).font(.callout).foregroundStyle(Color(theme.textSecondary))
                    }.padding(.top, 10)
                }
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
    private var selectedAccess: MobilePairingStore.Access {
        .init(workspaceID: UUID(uuidString: sharedWorkspace), writable: writable)
    }
    private func invite(_ entry: MobileAccessController.Entry) {
        controller.createInvitation(via: entry, access: selectedAccess)
    }
    private func accessTitle(_ access: MobilePairingStore.Access) -> String {
        let scope = access.workspaceID.map { id in controller.shareWorkspaces.first(where: { $0.id == id })?.name ?? text("share.unavailable") } ?? text("share.all")
        return scope + " · " + text(access.writable ? "share.writable" : "share.readOnly")
    }
    private func exportCertificate(iOS: Bool) {
        guard let data = controller.certificateExport(iOS: iOS) else { return }
        let panel = NSSavePanel()
        let ext = iOS ? "mobileconfig" : "cer"
        panel.nameFieldStringValue = "TheAll-Local-CA." + ext
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); exportError = nil }
            catch { exportError = text("lan.exportFailed") }
        }
    }
    private func qrCode(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 180, height: 180))
    }
}
