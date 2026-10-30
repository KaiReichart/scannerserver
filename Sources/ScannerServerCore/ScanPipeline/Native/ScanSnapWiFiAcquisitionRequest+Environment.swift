import Foundation

extension ScanSnapWiFiAcquisitionRequest {
    /// Builds a Wi-Fi acquisition request from the merged service and live scanner-setup
    /// environment. Shared by the native scan pipeline and the eSCL adapter so both acquire with
    /// identical scanner, client-address, and registration-port settings.
    init(
        scanEnvironment environment: [String: String],
        simplex: Bool,
        reusesArmedSession: Bool,
        outputURL: URL
    ) throws {
        func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        guard let scannerIP = nonEmpty(environment["SCANNER_IP"]) else {
            throw NativeScanConfigurationError.message(
                "SCAN_BACKEND=wifi requires SCANNER_IP from the live scanner setup."
            )
        }
        guard let pairingKey = nonEmpty(environment["SCAN_PAIRING_KEY"])
                ?? nonEmpty(environment["SCANSNAP_PAIRING_KEY"])
        else {
            throw NativeScanConfigurationError.message(
                "SCAN_BACKEND=wifi requires SCAN_PAIRING_KEY or SCANSNAP_PAIRING_KEY from the live scanner setup."
            )
        }

        let clientIPAddress: String?
        if let configured = nonEmpty(environment["SCANSNAP_CLIENT_IP"]) {
            do {
                clientIPAddress = try ScannerConfig.normalizeIPv4Address(configured)
            } catch {
                throw NativeScanConfigurationError.message(
                    "Invalid SCANSNAP_CLIENT_IP: \(configured)"
                )
            }
        } else {
            clientIPAddress = nil
        }
        let clientMACAddress: [UInt8]?
        if let configured = nonEmpty(environment["SCANSNAP_CLIENT_MAC"]) {
            do {
                clientMACAddress = try ScanSnapSetupEnvironmentConfiguration.macBytes(configured)
            } catch {
                throw NativeScanConfigurationError.message(
                    "Invalid SCANSNAP_CLIENT_MAC: \(configured)"
                )
            }
        } else {
            clientMACAddress = nil
        }
        let buttonConfiguration = ScanSnapButtonConfiguration(environment: environment)
        self.init(
            scannerIPAddress: scannerIP,
            identity: ScanSnapIdentity(pairingKey),
            clientIPAddress: clientIPAddress,
            clientMACAddress: clientMACAddress,
            clientInterface: nonEmpty(environment["SCANSNAP_CLIENT_INTERFACE"]) ?? "eth0",
            simplex: simplex,
            reusesArmedSession: reusesArmedSession,
            debug: environment["SCAN_WIFI_DEBUG"] == "true",
            outputURL: outputURL,
            registrationSourcePort: buttonConfiguration.registrationSourcePort,
            registrationPort: buttonConfiguration.registrationPort
        )
    }
}
