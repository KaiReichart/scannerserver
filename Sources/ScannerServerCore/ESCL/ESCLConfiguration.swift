import Foundation

/// Static description of the driverless eSCL ("AirScan") scanner that scannerserver exposes.
///
/// The iX500 Wi-Fi acquisition used here always captures colour JPEG sides at 300 dpi from the
/// automatic document feeder, so the advertised capabilities are deliberately narrow and honest.
public struct ESCLConfiguration: Equatable, Sendable {
    public static let basePath = "/eSCL"
    public static let serviceType = "_uscan._tcp"
    public static let protocolVersion = "2.63"
    public static let resolution = 300
    public static let feederCapacity = 50

    /// Scan-area limits in eSCL's 1/300-inch units (ScanSnap iX500 normal-mode limits).
    public static let minimumWidth = 600     // 50.8 mm
    public static let maximumWidth = 2_550   // 216 mm
    public static let minimumHeight = 600    // 50.8 mm
    public static let maximumHeight = 4_252  // 360 mm

    public let enabled: Bool
    public let bonjourEnabled: Bool
    public let serviceName: String
    public let makeAndModel: String
    public let uuid: String
    public let nextDocumentTimeout: Duration
    public let completedJobRetention: Duration

    public init(
        environment: [String: String],
        hostName: String = ProcessInfo.processInfo.hostName
    ) {
        enabled = Self.isTruthy(environment["SCAN_ESCL_ENABLED"] ?? "false")
        bonjourEnabled = enabled
            && Self.isTruthy(environment["SCAN_ESCL_BONJOUR_ENABLED"] ?? "true")
        serviceName = Self.nonEmpty(environment["SCAN_ESCL_NAME"]) ?? "ScanSnap iX500"
        makeAndModel = "Fujitsu ScanSnap iX500"
        if let configured = Self.nonEmpty(environment["SCAN_ESCL_UUID"]),
           let parsed = UUID(uuidString: configured) {
            uuid = parsed.uuidString.lowercased()
        } else {
            uuid = Self.stableUUID(seed: "scannerserver-escl|\(serviceName)|\(hostName)")
        }
        nextDocumentTimeout = .seconds(120)
        completedJobRetention = .seconds(300)
    }

    public init(
        enabled: Bool,
        bonjourEnabled: Bool = false,
        serviceName: String = "ScanSnap iX500",
        uuid: String = "00000000-0000-5000-8000-000000000000",
        nextDocumentTimeout: Duration = .seconds(120),
        completedJobRetention: Duration = .seconds(300)
    ) {
        self.enabled = enabled
        self.bonjourEnabled = bonjourEnabled
        self.serviceName = serviceName
        makeAndModel = "Fujitsu ScanSnap iX500"
        self.uuid = uuid
        self.nextDocumentTimeout = nextDocumentTimeout
        self.completedJobRetention = completedJobRetention
    }

    /// Name-based UUID (version 5 layout over SHA-256) so the scanner keeps one identity across
    /// container restarts and clients do not list it as a new device each time.
    static func stableUUID(seed: String) -> String {
        let hex = OCRWorkerSHA256.hexDigest(Data(seed.utf8))
        var bytes: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<16 {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }

    private static func isTruthy(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        default: false
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
