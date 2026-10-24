import SwiftUI
import AVFoundation
import VisionKit
import AFKCore

@main
struct AFKiOSApp: App {
    @StateObject private var model = RemoteModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            PhoneHome(model: model).task { model.restore() }
                .overlay {
                    if phase != .active { Color(.systemBackground).ignoresSafeArea().overlay(Image(systemName: "lock.fill").font(.largeTitle)) }
                }
                .onChange(of: phase) { _, next in
                    if next == .background { model.suspend() }
                    else if next == .active { model.activate() }
                }
        }
    }
}

struct PhoneHome: View {
    @ObservedObject var model: RemoteModel
    @State private var showPair = false
    @State private var closeTarget: SessionInfo?
    @State private var collapsedGroupIDs: Set<String> = []
    private var activeSessions: [SessionInfo] { model.visibleSessions.filter(\.running) }
    private var groups: [SessionGroup] {
        var seen: Set<String> = []
        return activeSessions.compactMap(\.group).filter { seen.insert($0.id).inserted }
    }
    private func title(_ session: SessionInfo) -> String { session.name }
    @ViewBuilder private func sessionRow(_ session: SessionInfo, hidden: Bool = false) -> some View {
        Group {
            if hidden {
                HStack {
                    sessionLabel(session, showGroup: true)
                    Spacer()
                    Button(L10n.text("Mostrar")) { model.showSession(session.id) }.buttonStyle(.bordered)
                }
            } else {
                NavigationLink {
                    PhoneTerminal(model: model, session: session, title: title(session))
                } label: { sessionLabel(session, showGroup: !session.running) }
                .disabled(!model.hostAvailable || session.closing == true)
            }
        }
        .contextMenu {
            if hidden { Button(L10n.text("Mostrar"), systemImage: "eye") { model.showSession(session.id) } }
            else { Button(L10n.text("Ocultar en este dispositivo"), systemImage: "eye.slash") { model.hideSession(session.id) } }
            Button(model.closeActionTitle(session), role: .destructive) {
                if session.running { closeTarget = session } else { model.closeSession(session.id) }
            }.disabled(!model.canCloseSession(session))
        }
    }
    private func sessionLabel(_ session: SessionInfo, showGroup: Bool) -> some View {
        HStack(spacing: 12) {
            SessionGroupMark(group: session.group)
            VStack(alignment: .leading, spacing: 5) {
                Text(title(session)).font(.body.weight(.medium)).lineLimit(2)
                if let context = session.context, !context.isEmpty { Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if showGroup, let group = session.group { Text(group.name).font(.caption).foregroundStyle(.secondary) }
                if model.sessions.filter({ $0.name == session.name && $0.context == session.context }).count > 1 {
                    Text(String(session.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text(L10n.text(session.closing == true ? "Cerrando…" : session.running ? "En ejecución · toca para abrir" : "Sesión terminada"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 48)
    }
    var body: some View {
        NavigationStack {
            Group {
                if !model.linked {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            Image(systemName: "terminal").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L10n.text("Tu Mac se queda.\nTu terminal va contigo.")).font(.largeTitle.weight(.semibold))
                                Text(L10n.text("Mira lo que está pasando y continúa desde aquí, en la misma sesión."))
                                    .font(.body).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 20) {
                                InstructionRow(number: "1", title: L10n.text("Abre AFK en tu Mac"), detail: L10n.text("Elige «Vincular iPhone»."))
                                InstructionRow(number: "2", title: L10n.text("Escanea el QR"), detail: L10n.text("Escanea el QR que aparece en tu Mac."))
                            }
                            Button { showPair = true } label: {
                                Text(L10n.text("Vincular mi Mac")).fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.borderedProminent)
                        }.padding(24).frame(maxWidth: 540, alignment: .leading).frame(maxWidth: .infinity)
                    }
                } else {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(model.hostName, systemImage: "desktopcomputer").font(.headline)
                                ConnectionIndicator(title: model.hostAvailable ? L10n.text("Mac disponible") : L10n.text("Mac sin conexión"), connected: model.hostAvailable)
                                if !model.hostAvailable {
                                    Text(L10n.text("Mantén AFK abierto en tu Mac para acceder a sus sesiones."))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Button(L10n.text("Volver a conectar"), systemImage: "arrow.clockwise") { model.reconnect() }
                                        .frame(minHeight: 44)
                                }
                            }.padding(.vertical, 8)
                        }
                        if let id = model.lastHiddenSessionID, let hidden = model.hiddenSessions.first(where: { $0.id == id }) {
                            Section {
                                Text(L10n.format("Ocultaste %@ en este dispositivo", hidden.name)).font(.subheadline)
                                Button(L10n.text("Deshacer")) { model.showSession(id) }
                            }
                        }
                        if model.sessions.isEmpty || activeSessions.contains(where: { $0.group == nil }) {
                            Section {
                                if model.sessions.isEmpty {
                                    Text(model.hostAvailable ? L10n.text("Comparte una sesión desde Dispositivos en tu Mac.") : L10n.text("Las sesiones aparecerán cuando tu Mac se conecte."))
                                        .foregroundStyle(.secondary).padding(.vertical, 8)
                                }
                                ForEach(activeSessions.filter { $0.group == nil }) { session in sessionRow(session) }
                            } header: { Text(L10n.text(groups.isEmpty ? "Tus sesiones" : "Sin grupo")) }
                        }
                        ForEach(groups) { group in
                            Section {
                                DisclosureGroup(isExpanded: Binding(
                                    get: { !collapsedGroupIDs.contains(group.id) },
                                    set: { if $0 { collapsedGroupIDs.remove(group.id) } else { collapsedGroupIDs.insert(group.id) } }
                                )) {
                                    ForEach(activeSessions.filter { $0.group?.id == group.id }) { session in sessionRow(session) }
                                } label: {
                                    HStack {
                                        Label { Text(group.name) } icon: { SessionGroupMark(group: group) }.foregroundStyle(AFKStyle.groupColor(group.color))
                                        Spacer()
                                        Text(String(activeSessions.filter { $0.group?.id == group.id }.count)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if model.visibleSessions.contains(where: { !$0.running }) {
                            Section(L10n.text("Terminadas")) {
                                ForEach(model.visibleSessions.filter { !$0.running }) { session in sessionRow(session) }
                            }
                        }
                        if !model.hiddenSessions.isEmpty {
                            Section {
                                DisclosureGroup(L10n.format("Ocultas (%lld)", model.hiddenSessions.count)) {
                                    ForEach(model.hiddenSessions) { session in sessionRow(session, hidden: true) }
                                }
                            } footer: { Text(L10n.text("Ocultar no detiene la terminal. Los grupos se organizan en el Mac.")) }
                        }
                    }
                }
            }
            .navigationTitle("AFK")
            .toolbar {
                if model.linked {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.text("Nueva sesión"), systemImage: "plus") { model.create() }
                            .disabled(!model.hostAvailable || !model.canCreate)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(L10n.text("Reconectar"), systemImage: "arrow.clockwise") { model.reconnect() }
                            Button(L10n.text("Vincular otro Mac…"), systemImage: "plus") { showPair = true }
                        } label: { Label(L10n.text("Opciones"), systemImage: "ellipsis.circle") }
                        .accessibilityLabel(L10n.text("Opciones de conexión"))
                    }
                }
            }
            .confirmationDialog(L10n.text(closeTarget?.canRemove == true ? "¿Cerrar y quitar esta sesión?" : "¿Terminar esta sesión?"), isPresented: Binding(get: { closeTarget != nil }, set: { if !$0 { closeTarget = nil } }), titleVisibility: .visible) {
                Button(L10n.text(closeTarget?.canRemove == true ? "Cerrar y quitar" : "Terminar sesión"), role: .destructive) {
                    if let target = closeTarget { model.closeSession(target.id) }; closeTarget = nil
                }
            } message: {
                Text([closeTarget?.group?.name, closeTarget?.name].compactMap { $0 }.joined(separator: " / ") + "\n" + L10n.text("Se detendrá la terminal. Su historial guardado se conservará."))
            }
            .sheet(isPresented: $showPair) { PairForm(model: model) }
            .alert(L10n.text("No se pudo completar la acción"), isPresented: Binding(
                get: { model.error != nil && !showPair },
                set: { if !$0 { model.error = nil } }
            )) { Button(L10n.text("Aceptar")) { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}

struct PairForm: View {
    @ObservedObject var model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var invitation = ""
    @State private var busy = false
    @State private var scanning = false
    @State private var origin: String?
    @State private var confirmOrigin = false
    @State private var completed = false
    var body: some View {
        NavigationStack {
            Form {
                if completed {
                    Text(L10n.text("Vinculado. Comparte sesiones desde tu Mac"))
                } else if busy {
                    if let code = model.comparisonCode {
                        Text(code).font(.system(size: 36, weight: .semibold, design: .monospaced))
                        Text(L10n.text("Confirma en tu Mac"))
                    } else { ProgressView(L10n.text("Conectando…")) }
                } else {
                    Section {
                        Label(L10n.text("En tu Mac, abre AFK y pulsa «Vincular iPhone»."), systemImage: "desktopcomputer")
                        if model.linked { Text(L10n.text("Este vínculo reemplazará en el iPhone al Mac que tienes guardado.")) }
                        Button(L10n.text("Escanear QR"), systemImage: "qrcode.viewfinder") {
                            Task {
                                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                                guard phase == .active else { return }
                                if allowed && DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                                    invitation = ""; origin = nil; scanning = true
                                }
                                else { model.error = L10n.text("Cámara no disponible. Puedes pegar la invitación o habilitar la cámara en Ajustes.") }
                            }
                        }
                    }
                    Section(L10n.text("Pegar invitación")) {
                        SecureField(L10n.text("Invitación segura"), text: $invitation)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(L10n.text("Continuar")) { validate() }.disabled(invitation.isEmpty)
                    }
                }
                if let error = model.error { InlineNotice(text: error) }
            }
            .navigationTitle(L10n.text("Vincular Mac"))
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(L10n.text(completed ? "Cerrar" : "Cancelar")) { model.cancelPairing(); invitation = ""; dismiss() }
            } }
            .onAppear { model.error = nil }
            .onDisappear { model.cancelPairing(); invitation = "" }
            .onChange(of: phase) { _, next in
                if next == .background { scanning = false; invitation = ""; origin = nil; confirmOrigin = false; model.cancelPairing() }
            }
            .interactiveDismissDisabled(busy)
            .sheet(isPresented: $scanning, onDismiss: { if !invitation.isEmpty { validate() } }) {
                NavigationStack {
                    PairingScanner(accept: { value in scanning = false; invitation = value }, unavailable: {
                        scanning = false
                        model.error = L10n.text("Cámara no disponible. Puedes pegar la invitación o habilitar la cámara en Ajustes.")
                    })
                        .navigationTitle(L10n.text("Escanear QR"))
                        .toolbar { Button(L10n.text("Cancelar")) { scanning = false } }
                }
            }
            .confirmationDialog(L10n.text("Conectar con este servidor"), isPresented: $confirmOrigin, titleVisibility: .visible) {
                Button(L10n.text("Continuar")) {
                    guard !busy else { return }
                    busy = true; model.error = nil
                    let value = invitation; invitation = ""
                    Task { await model.pair(invitation: value); busy = false; completed = model.error == nil }
                }
                Button(L10n.text("Cancelar"), role: .cancel) { invitation = ""; origin = nil }
            } message: { Text(origin ?? "") }
        }
    }
    private func validate() {
        do { origin = try SecureInvitation.decode(invitation).server; confirmOrigin = true }
        catch { model.error = error.localizedDescription; invitation = "" }
    }
}

struct PhoneTerminal: View {
    @ObservedObject var model: RemoteModel
    let session: SessionInfo
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEnd = false
    @State private var draft = ""
    @State private var mirroredDraft = ""
    private var currentSession: SessionInfo { model.sessions.first(where: { $0.id == session.id }) ?? session }
    private var terminalTitle: String {
        let duplicate = model.sessions.filter { $0.name == currentSession.name && $0.context == currentSession.context }.count > 1
        return currentSession.name + (duplicate ? " · " + String(session.id.prefix(8)) : "")
    }
    private var running: Bool { model.sessions.first(where: { $0.id == session.id })?.running ?? false }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SessionGroupMark(group: currentSession.group)
                    VStack(alignment: .leading, spacing: 2) {
                        if let group = currentSession.group { Text(group.name).font(.caption.weight(.semibold)) }
                        if let context = currentSession.context { Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                Label(model.terminalStatus, systemImage: model.canWrite ? "keyboard" : "eye")
                    .font(.subheadline.weight(.medium))
                if let notice = model.sessionNotice { InlineNotice(text: notice).textSelection(.enabled) }
                if let diagnostic = model.diagnostic {
                    Button(L10n.text("Copiar diagnóstico"), systemImage: "doc.on.doc") {
                        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                        UIPasteboard.general.string = diagnostic + " | iOS " + UIDevice.current.systemVersion + " | AFK " + version + " (" + build + ")"
                    }.font(.caption).frame(minHeight: 44)
                }
                if model.loadingHistory { ProgressView() }
                if let expiry = model.selectedInfo?.controlExpiresAt {
                    Text(L10n.text("Control autorizado hasta") + " " + expiry.formatted(date: .omitted, time: .shortened)).font(.caption)
                } else if model.ready { Text(L10n.text("Solo lectura. Autoriza el control desde el Mac.")).font(.caption) }
                if running && model.ready {
                    Button(model.canWrite ? L10n.text("Pasar a solo lectura") : L10n.text("Escribir desde aquí")) {
                        if model.canWrite { model.release() } else { model.claim() }
                    }.buttonStyle(.bordered).frame(minHeight: 44).disabled(!model.canClaim)
                } else if !model.hostAvailable || running {
                    Button(L10n.text("Volver a conectar"), systemImage: "arrow.clockwise") { model.reconnect() }
                        .frame(minHeight: 44)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            TerminalCanvas(feed: model.feed, editable: model.canWrite && running, input: { releaseDraft(); model.input($0) }, resize: model.resize)
            if model.canWrite && running {
                HStack(spacing: 8) {
                    // A native field gets reliable iOS dictation; each edit reaches the terminal as it happens.
                    TextField(L10n.text("Escribe o dicta un comando"), text: $draft)
                        .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.send).onSubmit(sendDraft)
                        .onChange(of: draft) { _, next in
                            let plain = TerminalLineEdit.plain(next)
                            guard plain == next else { draft = plain; return }
                            let edit = TerminalLineEdit.bytes(from: mirroredDraft, to: next)
                            if edit.isEmpty || model.input(edit) { mirroredDraft = next } else { releaseDraft() }
                        }
                    Button(L10n.text("Enviar"), systemImage: "return", action: sendDraft)
                        .labelStyle(.iconOnly).buttonStyle(.borderedProminent).frame(minWidth: 44, minHeight: 44)
                }.padding(.horizontal, 12).padding(.top, 6)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach([("Esc", "\u{1b}"), ("Tab", "\t"), ("Ctrl+C", "\u{3}"), ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"), ("←", "\u{1b}[D"), ("→", "\u{1b}[C")], id: \.0) { key in
                            Button(key.0) { releaseDraft(); model.input(Data(key.1.utf8)) }
                                .font(.subheadline.monospaced()).frame(minWidth: 44, minHeight: 44)
                                .accessibilityLabel(keyLabel(key.0))
                        }
                    }.padding(.horizontal, 12)
                }.scrollIndicators(.hidden).buttonStyle(.bordered).padding(.vertical, 4)
            } else {
                Text(L10n.text("Desliza la terminal para ver las demás columnas."))
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .onChange(of: running) { _, _ in releaseDraft() }
        .confirmationDialog(L10n.text(currentSession.canRemove == true ? "¿Cerrar y quitar esta sesión?" : "¿Terminar esta sesión?"), isPresented: $confirmEnd, titleVisibility: .visible) {
            Button(L10n.text(currentSession.canRemove == true ? "Cerrar y quitar" : "Terminar sesión"), role: .destructive) { model.closeSession(session.id) }
        } message: { Text([currentSession.group?.name, currentSession.name].compactMap { $0 }.joined(separator: " / ") + "\n" + L10n.text("Se detendrá la terminal. Su historial guardado se conservará.")) }
        .navigationTitle(terminalTitle).navigationBarTitleDisplayMode(.inline)
        .onAppear { model.attach(session.id) }.onDisappear { model.leave() }
        .onChange(of: model.selected) { _, selection in if selection == nil { dismiss() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L10n.text("Reconectar"), systemImage: "arrow.clockwise") { model.reconnect() }
                    Button(L10n.text("Ocultar en este dispositivo"), systemImage: "eye.slash") { model.hideSession(session.id); dismiss() }
                    Button(model.closeActionTitle(currentSession), role: .destructive) {
                        if running { confirmEnd = true } else { model.closeSession(session.id) }
                    }.disabled(!model.canTerminate)
                } label: { Label(L10n.text("Opciones de sesión"), systemImage: "ellipsis.circle") }
            }
        }
    }
    private func sendDraft() {
        // The text is already on the terminal line; Enter runs it and the field starts over.
        releaseDraft(); model.input(Data("\r".utf8))
    }
    /// Leaves whatever is on the terminal line there and stops mirroring it.
    private func releaseDraft() { mirroredDraft = ""; draft = "" }
    private func keyLabel(_ key: String) -> String {
        switch key {
        case "↑": return L10n.text("Flecha arriba")
        case "↓": return L10n.text("Flecha abajo")
        case "←": return L10n.text("Flecha izquierda")
        case "→": return L10n.text("Flecha derecha")
        case "Ctrl+C": return L10n.text("Control C, interrumpir comando")
        default: return key
        }
    }
}

struct PairingScanner: UIViewControllerRepresentable {
    let accept: (String) -> Void
    let unavailable: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(accept: accept, unavailable: unavailable) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() } catch { DispatchQueue.main.async { context.coordinator.unavailable() } }
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        coordinator.finished = true; controller.stopScanning()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let accept: (String) -> Void
        var finished = false
        let unavailable: () -> Void
        init(accept: @escaping (String) -> Void, unavailable: @escaping () -> Void) { self.accept = accept; self.unavailable = unavailable }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            guard !finished else { return }; finished = true; scanner.stopScanning(); unavailable()
        }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            consume(addedItems, scanner: scanner)
        }
        func dataScanner(_ scanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            consume(updatedItems, scanner: scanner)
        }
        private func consume(_ items: [RecognizedItem], scanner: DataScannerViewController) {
            guard !finished else { return }
            for item in items {
                guard case .barcode(let barcode) = item, let value = barcode.payloadStringValue,
                      value.utf8.count <= 2048,
                      (try? SecureInvitation.decode(value)) != nil || value.hasPrefix("AFK2:") else { continue }
                finished = true; scanner.stopScanning(); accept(value); return
            }
        }
    }
}
