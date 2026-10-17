import SwiftUI
import AVFoundation
import VisionKit
import AFKCore

@main
struct AFKiOSApp: App {
    @StateObject private var model = RemoteModel()
    @Environment(\.scenePhase) private var phase
    @State private var needsResume = false
    var body: some Scene {
        WindowGroup {
            PhoneHome(model: model).task { model.restore() }
                .overlay {
                    if phase != .active { Color(.systemBackground).ignoresSafeArea().overlay(Image(systemName: "lock.fill").font(.largeTitle)) }
                }
                .onChange(of: phase) { _, next in
                    if next == .background { needsResume = true; model.suspend() }
                    else if next == .active && needsResume { needsResume = false; if model.linked { model.reconnect() } }
                }
        }
    }
}

struct PhoneHome: View {
    @ObservedObject var model: RemoteModel
    @State private var showPair = false
    private func title(_ session: SessionInfo) -> String {
        guard session.name == "Shell", let index = model.sessions.firstIndex(where: { $0.id == session.id }) else { return session.name }
        return L10n.format("Terminal %lld", index + 1)
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
                        Section {
                            if model.sessions.isEmpty {
                                Text(model.hostAvailable ? L10n.text("Comparte una sesión desde Dispositivos en tu Mac.") : L10n.text("Las sesiones aparecerán cuando tu Mac se conecte."))
                                    .foregroundStyle(.secondary).padding(.vertical, 8)
                            }
                            ForEach(model.sessions) { session in
                                NavigationLink {
                                    PhoneTerminal(model: model, session: session, title: title(session))
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "terminal").font(.title2).foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(title(session)).font(.body.weight(.medium))
                                            Text(session.running ? L10n.text("En ejecución · toca para abrir") : L10n.text("Sesión terminada"))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.frame(minHeight: 48)
                                }.disabled(!model.hostAvailable)
                            }
                            Button { model.create() } label: {
                                Label(L10n.text("Nueva sesión"), systemImage: "plus").frame(minHeight: 44)
                            }.disabled(!model.hostAvailable || !model.canCreate)
                        } header: { Text(L10n.text("Tus sesiones")) }
                        footer: { Text(L10n.text("Las sesiones se ejecutan en tu Mac. Salir de AFK en el Mac las detiene.")) }
                    }
                }
            }
            .navigationTitle("AFK")
            .toolbar {
                if model.linked {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(L10n.text("Reconectar"), systemImage: "arrow.clockwise") { model.reconnect() }
                            Button(L10n.text("Vincular otro Mac…"), systemImage: "plus") { showPair = true }
                        } label: { Label(L10n.text("Opciones"), systemImage: "ellipsis.circle") }
                        .accessibilityLabel(L10n.text("Opciones de conexión"))
                    }
                }
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
    @State private var confirmEnd = false
    @State private var showingHistory = false
    private var running: Bool { model.sessions.first(where: { $0.id == session.id })?.running ?? false }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label(model.terminalStatus, systemImage: model.canWrite ? "keyboard" : "eye")
                    .font(.subheadline.weight(.medium))
                if let notice = model.sessionNotice { InlineNotice(text: notice) }
                if let progress = model.historyProgress { ProgressView(value: progress) }
                HistoryRecordingStatus(feed: model.feed)
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
            TerminalCanvas(feed: model.feed, editable: model.canWrite && running, input: model.input, resize: model.resize)
            if model.canWrite && running {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach([("Esc", "\u{1b}"), ("Tab", "\t"), ("Ctrl+C", "\u{3}"), ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"), ("←", "\u{1b}[D"), ("→", "\u{1b}[C")], id: \.0) { key in
                            Button(key.0) { model.input(Data(key.1.utf8)) }
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
        .confirmationDialog(L10n.text("¿Terminar esta sesión?"), isPresented: $confirmEnd) {
            Button(L10n.text("Terminar sesión"), role: .destructive) { model.terminate() }
        }
        .sheet(isPresented: $showingHistory) {
            NavigationStack {
                if let entry = model.feed.history?.entry {
                    RecordedTerminal(entry: entry)
                        .navigationTitle(L10n.text("Historial completo"))
                        .toolbar { Button(L10n.text("Cerrar")) { showingHistory = false } }
                }
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .onAppear { model.attach(session.id) }.onDisappear { model.leave() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L10n.text("Historial completo"), systemImage: "clock") { showingHistory = true }
                        .disabled(!model.ready || model.feed.history == nil)
                    Button(L10n.text("Reconectar"), systemImage: "arrow.clockwise") { model.reconnect() }
                    Button(L10n.text("Terminar sesión"), role: .destructive) { confirmEnd = true }.disabled(!model.canTerminate)
                } label: { Label(L10n.text("Opciones de sesión"), systemImage: "ellipsis.circle") }
            }
        }
    }
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
