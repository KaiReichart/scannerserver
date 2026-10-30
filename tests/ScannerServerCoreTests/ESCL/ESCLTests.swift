import Foundation
import Hummingbird
import HummingbirdTesting
@testable import ScannerServerCore
import Testing
#if canImport(FoundationXML)
import FoundationXML
#endif

@Suite("eSCL scan settings and documents")
struct ESCLDocumentTests {
    @Test("macOS-style ScanSettings select duplex JPEG from the feeder")
    func parsesTypicalScanSettings() throws {
        let settings = try ESCLScanSettings(xml: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.6</pwg:Version>
          <scan:Intent>Document</scan:Intent>
          <pwg:ScanRegions pwg:MustHonor="false">
            <pwg:ScanRegion>
              <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
              <pwg:Height>3300</pwg:Height><pwg:Width>2550</pwg:Width>
              <pwg:XOffset>0</pwg:XOffset><pwg:YOffset>0</pwg:YOffset>
            </pwg:ScanRegion>
          </pwg:ScanRegions>
          <pwg:InputSource>Feeder</pwg:InputSource>
          <scan:Duplex>true</scan:Duplex>
          <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
          <scan:ColorMode>RGB24</scan:ColorMode>
          <scan:XResolution>300</scan:XResolution>
          <scan:YResolution>300</scan:YResolution>
        </scan:ScanSettings>
        """.utf8))

        #expect(settings == ESCLScanSettings(
            duplex: true,
            documentFormat: .jpeg,
            colorMode: "RGB24",
            resolution: 300,
            intent: "Document"
        ))
    }

    @Test("DocumentFormatExt wins over the legacy DocumentFormat and defaults are simplex JPEG")
    func formatPrecedenceAndDefaults() throws {
        let pdf = try ESCLScanSettings(xml: Data("""
        <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:DocumentFormat>application/octet-stream</pwg:DocumentFormat>
          <scan:DocumentFormatExt>application/pdf</scan:DocumentFormatExt>
        </scan:ScanSettings>
        """.utf8))
        #expect(pdf.documentFormat == .pdf)
        #expect(pdf.duplex == false)

        let minimal = try ESCLScanSettings(xml: Data(
            #"<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"/>"#.utf8
        ))
        #expect(minimal == ESCLScanSettings())
    }

    @Test("Unsupported sources, formats, and malformed bodies are rejected")
    func rejectsUnsupportedSettings() {
        #expect(throws: ESCLScanSettingsError.unsupportedInputSource("Platen")) {
            try ESCLScanSettings(xml: Data("""
            <scan:ScanSettings xmlns:scan="s" xmlns:pwg="p"><pwg:InputSource>Platen</pwg:InputSource></scan:ScanSettings>
            """.utf8))
        }
        #expect(throws: ESCLScanSettingsError.unsupportedDocumentFormat("image/png")) {
            try ESCLScanSettings(xml: Data("""
            <scan:ScanSettings xmlns:scan="s"><scan:DocumentFormatExt>image/png</scan:DocumentFormatExt></scan:ScanSettings>
            """.utf8))
        }
        #expect(throws: ESCLScanSettingsError.self) {
            try ESCLScanSettings(xml: Data("<scan:ScanSettings>".utf8))
        }
        #expect(throws: ESCLScanSettingsError.self) {
            try ESCLScanSettings(xml: Data("<Other/>".utf8))
        }
    }

    @Test("Capabilities advertise only the iX500 feeder at 300 dpi colour")
    func capabilitiesDocument() throws {
        let xml = ESCLDocuments.capabilities(
            configuration: ESCLConfiguration(enabled: true, uuid: "4f1c-test"),
            adminURI: "http://scanner.local:8080/",
            serialNumber: "AWRHC08122 & <x>"
        )
        #expect(XMLParser(data: Data(xml.utf8)).parse())
        #expect(xml.contains("<scan:AdfSimplexInputCaps>"))
        #expect(xml.contains("<scan:AdfDuplexInputCaps>"))
        #expect(xml.contains("<scan:ColorMode>RGB24</scan:ColorMode>"))
        #expect(xml.contains("<scan:XResolution>300</scan:XResolution>"))
        #expect(xml.contains("<pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>"))
        #expect(xml.contains("<scan:DocumentFormatExt>application/pdf</scan:DocumentFormatExt>"))
        #expect(xml.contains("<pwg:SerialNumber>AWRHC08122 &amp; &lt;x&gt;</pwg:SerialNumber>"))
        #expect(xml.contains("<scan:AdminURI>http://scanner.local:8080/</scan:AdminURI>"))
        #expect(!xml.contains("Platen"))
    }

    @Test("Status lists jobs newest first with transfer counts")
    func statusDocument() {
        let created = Date(timeIntervalSince1970: 1_000)
        let xml = ESCLDocuments.status(
            ESCLStatusSnapshot(
                state: .idle,
                adfState: .empty,
                jobs: [ESCLJobSnapshot(
                    id: "abc",
                    created: created,
                    state: .completed,
                    stateReason: "JobCompletedSuccessfully",
                    imagesCompleted: 4,
                    imagesToTransfer: 1
                )]
            ),
            now: created.addingTimeInterval(12)
        )
        #expect(XMLParser(data: Data(xml.utf8)).parse())
        #expect(xml.contains("<pwg:State>Idle</pwg:State>"))
        #expect(xml.contains("<scan:AdfState>ScannerAdfEmpty</scan:AdfState>"))
        #expect(xml.contains("<pwg:JobUri>/eSCL/ScanJobs/abc</pwg:JobUri>"))
        #expect(xml.contains("<scan:Age>12</scan:Age>"))
        #expect(xml.contains("<pwg:ImagesCompleted>4</pwg:ImagesCompleted>"))
        #expect(xml.contains("<pwg:ImagesToTransfer>1</pwg:ImagesToTransfer>"))
        #expect(xml.contains("<pwg:JobState>Completed</pwg:JobState>"))
    }

    @Test("Configuration is opt-in and keeps a stable name-based UUID")
    func configuration() throws {
        #expect(ESCLConfiguration(environment: [:]).enabled == false)
        #expect(ESCLConfiguration(environment: [:]).bonjourEnabled == false)

        let enabled = ESCLConfiguration(
            environment: ["SCAN_ESCL_ENABLED": "true", "SCAN_ESCL_NAME": "Office"],
            hostName: "pi"
        )
        #expect(enabled.enabled)
        #expect(enabled.bonjourEnabled)
        #expect(enabled.serviceName == "Office")
        let again = ESCLConfiguration(
            environment: ["SCAN_ESCL_ENABLED": "true", "SCAN_ESCL_NAME": "Office"],
            hostName: "pi"
        )
        #expect(enabled.uuid == again.uuid)
        let parsed = try #require(UUID(uuidString: enabled.uuid))
        #expect(parsed.uuidString.lowercased() == enabled.uuid)
        #expect(Array(enabled.uuid)[14] == "5")

        let otherHost = ESCLConfiguration(
            environment: ["SCAN_ESCL_ENABLED": "true", "SCAN_ESCL_NAME": "Office"],
            hostName: "nas"
        )
        #expect(otherHost.uuid != enabled.uuid)

        let pinned = ESCLConfiguration(environment: [
            "SCAN_ESCL_ENABLED": "1",
            "SCAN_ESCL_BONJOUR_ENABLED": "false",
            "SCAN_ESCL_UUID": "8E0F4C2A-1B2C-4D5E-8F90-0123456789AB",
        ])
        #expect(pinned.bonjourEnabled == false)
        #expect(pinned.uuid == "8e0f4c2a-1b2c-4d5e-8f90-0123456789ab")
    }

    @Test("Bonjour publication advertises _uscan._tcp with the eSCL TXT keys")
    func bonjourPublication() {
        let publication = ESCLBonjourPublication(
            configuration: ESCLConfiguration(enabled: true, serviceName: "ScanSnap iX500", uuid: "u-1"),
            port: 8080
        )
        let request = publication.publicationRequest
        #expect(request.executable == "avahi-publish-service")
        #expect(Array(request.arguments.prefix(4)) == [
            "--no-fail", "ScanSnap iX500", "_uscan._tcp", "8080",
        ])
        #expect(request.arguments.contains("rs=eSCL"))
        #expect(request.arguments.contains("uuid=u-1"))
        #expect(request.arguments.contains("pdl=image/jpeg,application/pdf"))
        #expect(request.arguments.contains("is=adf"))
        #expect(request.arguments.contains("duplex=T"))
    }
}

@Suite("eSCL HTTP adapter")
struct ESCLRouteTests {
    @Test("Routes are absent unless eSCL is enabled")
    func disabledByDefault() async throws {
        let fixture = try ESCLFixture(acquirer: FakeWiFiAcquirer(), esclEnabled: false)
        defer { fixture.remove() }
        try await fixture.application().test(.router) { client in
            try await client.execute(uri: "/eSCL/ScannerCapabilities", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("A JPEG job streams each side, then reports completion")
    func jpegJobStreamsPages() async throws {
        let pages = [jpeg(1), jpeg(2), jpeg(3)]
        let acquirer = FakeWiFiAcquirer(pages: pages)
        let fixture = try ESCLFixture(acquirer: acquirer)
        defer { fixture.remove() }
        let events = EventRecorder()
        await fixture.scanJobs.addEventHandler { [sessions = fixture.sessions] event in
            await events.record(event)
            // Emulates the physical-button runtime handing its armed session to the scan.
            if case .started = event {
                await sessions.prepareForAcquisition(reusingArmedSession: true)
            }
        }

        try await fixture.application().test(.router) { client in
            try await client.execute(uri: "/eSCL/ScannerStatus", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("<pwg:State>Idle</pwg:State>"))
            }

            let absoluteLocation = try await client.execute(
                uri: "/eSCL/ScanJobs",
                method: .post,
                headers: [.contentType: "text/xml"],
                body: ByteBuffer(string: scanSettingsXML(duplex: true, format: "image/jpeg"))
            ) { response -> String in
                #expect(response.status == .created)
                return try #require(response.headers[.location])
            }
            // Clients resolve the job against the Host they connected to.
            #expect(absoluteLocation.hasPrefix("http://localhost/eSCL/ScanJobs/"))
            let location = try #require(URL(string: absoluteLocation)?.path)

            for page in pages {
                try await client.execute(uri: "\(location)/NextDocument", method: .get) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.contentType] == "image/jpeg")
                    #expect(Data(buffer: response.body) == page)
                }
            }
            try await client.execute(uri: "\(location)/NextDocument", method: .get) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/eSCL/ScannerStatus", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(body.contains("<pwg:State>Idle</pwg:State>"))
                #expect(body.contains("<pwg:JobState>Completed</pwg:JobState>"))
                #expect(body.contains("<pwg:ImagesCompleted>3</pwg:ImagesCompleted>"))
            }
            try await client.execute(uri: location, method: .delete) { response in
                #expect(response.status == .ok)
            }
        }

        let request = try #require(await acquirer.requests.first)
        #expect(request.simplex == false)
        #expect(request.reusesArmedSession)
        #expect(request.scannerIPAddress == "192.0.2.10")
        #expect(request.clientIPAddress == "192.0.2.20")
        #expect(await events.events == [
            .started(trigger: .escl),
            .finished(succeeded: true),
        ])
        #expect(await fixture.scanJobs.state.status == "done")
        #expect(fixture.workDirectories().isEmpty)
    }

    @Test("A PDF job returns one assembled document from the acquisition")
    func pdfJobReturnsDocument() async throws {
        let acquirer = FakeWiFiAcquirer(pages: [jpeg(1), jpeg(2)])
        let fixture = try ESCLFixture(acquirer: acquirer)
        defer { fixture.remove() }

        try await fixture.application().test(.router) { client in
            let location = try await client.execute(
                uri: "/eSCL/ScanJobs",
                method: .post,
                body: ByteBuffer(string: scanSettingsXML(duplex: false, format: "application/pdf"))
            ) { response -> String in
                #expect(response.status == .created)
                return try #require(response.headers[.location].flatMap { URL(string: $0)?.path })
            }
            try await client.execute(uri: "\(location)/NextDocument", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/pdf")
                #expect(Data(buffer: response.body) == FakeWiFiAcquirer.pdfBytes(pageCount: 2))
            }
            try await client.execute(uri: "\(location)/NextDocument", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
        #expect(await acquirer.requests.first?.simplex == true)
        #expect(fixture.workDirectories().isEmpty)
    }

    @Test("An empty feeder aborts the job and reports ScannerAdfEmpty")
    func emptyFeeder() async throws {
        let fixture = try ESCLFixture(acquirer: FakeWiFiAcquirer(failure: .noDocument))
        defer { fixture.remove() }

        try await fixture.application().test(.router) { client in
            let location = try await client.execute(
                uri: "/eSCL/ScanJobs",
                method: .post,
                body: ByteBuffer(string: scanSettingsXML(duplex: false, format: "image/jpeg"))
            ) { response -> String in
                try #require(response.headers[.location].flatMap { URL(string: $0)?.path })
            }
            try await client.execute(uri: "\(location)/NextDocument", method: .get) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/eSCL/ScannerStatus", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(body.contains("<scan:AdfState>ScannerAdfEmpty</scan:AdfState>"))
                #expect(body.contains("<pwg:JobState>Aborted</pwg:JobState>"))
            }
        }
        let state = await fixture.scanJobs.state
        #expect(state.status == "failed")
        #expect(state.error == "No document in scanner.")
    }

    @Test("A second job is refused while one is scanning, and DELETE cancels it")
    func busyAndCancel() async throws {
        let acquirer = FakeWiFiAcquirer(pages: [jpeg(1)], holdAfterPages: true)
        let fixture = try ESCLFixture(acquirer: acquirer)
        defer { fixture.remove() }

        try await fixture.application().test(.router) { client in
            let body = scanSettingsXML(duplex: false, format: "image/jpeg")
            let location = try await client.execute(
                uri: "/eSCL/ScanJobs", method: .post, body: ByteBuffer(string: body)
            ) { response -> String in
                try #require(response.headers[.location].flatMap { URL(string: $0)?.path })
            }
            try await client.execute(uri: "\(location)/NextDocument", method: .get) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/eSCL/ScanJobs", method: .post, body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers[.retryAfter] == "5")
            }
            try await client.execute(uri: "/eSCL/ScannerStatus", method: .get) { response in
                #expect(String(buffer: response.body).contains("<pwg:State>Processing</pwg:State>"))
            }
            try await client.execute(uri: location, method: .delete) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(uri: "\(location)/NextDocument", method: .get) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/eSCL/ScannerStatus", method: .get) { response in
                #expect(String(buffer: response.body).contains("<pwg:JobState>Canceled</pwg:JobState>"))
            }
        }
        #expect(await fixture.scanJobs.state.status == "cancelled")
    }

    @Test("Scan jobs are refused until the scanner is configured, and bad settings are rejected")
    func unavailableAndInvalid() async throws {
        let unconfigured = try ESCLFixture(acquirer: FakeWiFiAcquirer(), scannerConfigured: false)
        defer { unconfigured.remove() }
        try await unconfigured.application().test(.router) { client in
            try await client.execute(
                uri: "/eSCL/ScanJobs",
                method: .post,
                body: ByteBuffer(string: scanSettingsXML(duplex: false, format: "image/jpeg"))
            ) { response in
                #expect(response.status == .serviceUnavailable)
            }
            try await client.execute(uri: "/eSCL/ScannerStatus", method: .get) { response in
                #expect(String(buffer: response.body).contains("<pwg:State>Stopped</pwg:State>"))
            }
        }

        let configured = try ESCLFixture(acquirer: FakeWiFiAcquirer())
        defer { configured.remove() }
        try await configured.application().test(.router) { client in
            try await client.execute(
                uri: "/eSCL/ScanJobs",
                method: .post,
                body: ByteBuffer(string: scanSettingsXML(duplex: false, format: "image/png"))
            ) { response in
                #expect(response.status == .conflict)
            }
            try await client.execute(
                uri: "/eSCL/ScanJobs", method: .post, body: ByteBuffer(string: "not xml")
            ) { response in
                #expect(response.status == .badRequest)
            }
            try await client.execute(uri: "/eSCL/ScanJobs/missing/NextDocument", method: .get) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/eSCL/ScannerCapabilities", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/xml; charset=utf-8")
                #expect(String(buffer: response.body).contains("<pwg:SerialNumber>AWRHC08122</pwg:SerialNumber>"))
            }
        }
        #expect(await configured.scanJobs.state.status == "idle")
    }
}

// MARK: - Fixtures

private func jpeg(_ marker: UInt8) -> Data {
    Data([0xFF, 0xD8, 0xFF, 0xE0, marker, marker, 0xFF, 0xD9])
}

private func scanSettingsXML(duplex: Bool, format: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
      <pwg:Version>2.63</pwg:Version>
      <pwg:InputSource>Feeder</pwg:InputSource>
      <scan:Duplex>\(duplex)</scan:Duplex>
      <scan:DocumentFormatExt>\(format)</scan:DocumentFormatExt>
      <scan:ColorMode>RGB24</scan:ColorMode>
      <scan:XResolution>300</scan:XResolution>
      <scan:YResolution>300</scan:YResolution>
    </scan:ScanSettings>
    """
}

private actor EventRecorder {
    private(set) var events: [ScanJobEvent] = []
    func record(_ event: ScanJobEvent) { events.append(event) }
}

private actor FakeWiFiAcquirer: ScanSnapWiFiAcquiring {
    private let pages: [Data]
    private let failure: ScanSnapAcquisitionError?
    private let holdAfterPages: Bool
    private(set) var requests: [ScanSnapWiFiAcquisitionRequest] = []

    init(
        pages: [Data] = [],
        failure: ScanSnapAcquisitionError? = nil,
        holdAfterPages: Bool = false
    ) {
        self.pages = pages
        self.failure = failure
        self.holdAfterPages = holdAfterPages
    }

    static func pdfBytes(pageCount: Int) -> Data {
        Data("%PDF-1.4 fake \(pageCount) pages\n".utf8)
    }

    func acquire(
        _ request: ScanSnapWiFiAcquisitionRequest,
        pageHandler: (@Sendable (ScanSnapAcquiredPage) async throws -> Void)?
    ) async throws -> ScanSnapWiFiAcquisitionResult {
        requests.append(request)
        if let failure { throw failure }
        for (index, page) in pages.enumerated() {
            try await pageHandler?(ScanSnapAcquiredPage(pageNumber: index + 1, jpegData: page))
        }
        if holdAfterPages {
            while true { try await Task.sleep(for: .milliseconds(10)) }
        }
        try Self.pdfBytes(pageCount: pages.count).write(to: request.outputURL)
        return ScanSnapWiFiAcquisitionResult(pageCount: pages.count)
    }
}

private struct UnusedNativeScanner: NativeScanExecuting {
    func scan(configuration: ScanPipelineConfiguration) async throws -> NativeScanResult {
        Issue.record("The native pipeline must not run for eSCL jobs")
        return NativeScanResult(process: ProcessResult(exitStatus: 1))
    }
}

private actor ConfiguredSetupService: ScannerSetupServing {
    private let configured: Bool

    init(configured: Bool) {
        self.configured = configured
    }

    func state() -> ScannerSetupState {
        ScannerSetupState(
            serviceAvailable: true,
            configured: configured,
            name: "ScanSnap",
            ipAddress: "192.0.2.10",
            serial: "AWRHC08122",
            scannerEnvironment: configured ? [
                "SCANNER_IP": "192.0.2.10",
                "SCAN_PAIRING_KEY": "pairing-secret",
                "SCANSNAP_CLIENT_IP": "192.0.2.20",
                "SCANSNAP_CLIENT_MAC": "02:00:00:00:00:01",
            ] : [:]
        )
    }

    func discoveryInProgress() -> Bool { false }
    func ensureDiscoveryStarted() {}
    func shutdown() {}
    func discover() -> ScannerSetupOutcome { .unavailable }
    func select(deviceID: String) -> ScannerSetupOutcome { .unavailable }
    func configureManually(ipAddress: String, credential: String) -> ScannerSetupOutcome { .unavailable }
    func clear() -> ScannerSetupOutcome { .cleared }
}

private struct ESCLFixture: Sendable {
    let root: URL
    let scanJobs: ScanJobActor
    let sessions: ScanSnapAcquisitionSessionCoordinator
    let dependencies: ScannerServerDependencies

    init(
        acquirer: some ScanSnapWiFiAcquiring,
        esclEnabled: Bool = true,
        scannerConfigured: Bool = true
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outputDirectory = root.appendingPathComponent("scans", isDirectory: true)
        let workRoot = root.appendingPathComponent("escl-work", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        let environment = [
            "SCAN_BACKEND": "wifi",
            "SCAN_OUTPUT_DIR": outputDirectory.path,
            "SCAN_SETTINGS_PATH": outputDirectory.appendingPathComponent(".scanner-settings.json").path,
            "SCANNER_CONFIG_PATH": outputDirectory.appendingPathComponent(".scannerserver-scanner.json").path,
        ]
        let webUpdates = WebUpdateNotifier()
        scanJobs = ScanJobActor(nativeScanner: UnusedNativeScanner(), webUpdates: webUpdates)
        sessions = ScanSnapAcquisitionSessionCoordinator()
        let escl = esclEnabled
            ? ESCLScanService(
                configuration: ESCLConfiguration(
                    enabled: true,
                    uuid: "4f1c0000-0000-5000-8000-000000000001",
                    nextDocumentTimeout: .seconds(5)
                ),
                scanJobs: scanJobs,
                acquisitionSessions: sessions,
                acquirer: acquirer,
                workDirectoryRoot: workRoot
            )
            : nil
        dependencies = ScannerServerDependencies(
            settingsStore: ScanSettingsStore(environment: environment),
            scanJobs: scanJobs,
            scanSnapAcquisitionSessions: sessions,
            outputPathResolver: ScanOutputPathResolver(outputDirectory: outputDirectory),
            scannerSetup: ConfiguredSetupService(configured: scannerConfigured),
            webUpdates: webUpdates,
            environment: environment,
            escl: escl
        )
    }

    func application() throws -> some ApplicationProtocol {
        try ScannerServerApplication.make(
            configuration: ScannerServerServiceConfiguration(hostname: "127.0.0.1", port: 8080),
            dependencies: dependencies
        )
    }

    func workDirectories() -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("escl-work").path
        )) ?? []
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
