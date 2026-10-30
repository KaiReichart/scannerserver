import Foundation
import JLog

/// Advertises the eSCL endpoint as `_uscan._tcp` so macOS Image Capture, Windows, iOS, and
/// sane-airscan discover the scanner without a driver. Like the OCR worker advertisement, this
/// owns a cancellable `avahi-publish-service` subprocess and needs a reachable Avahi daemon.
public struct ESCLBonjourPublication: Equatable, Sendable {
    public let configuration: ESCLConfiguration
    public let port: Int

    public init(configuration: ESCLConfiguration, port: Int) {
        self.configuration = configuration
        self.port = port
    }

    public var txtRecords: [String] {
        [
            "txtvers=1",
            "vers=\(ESCLConfiguration.protocolVersion)",
            "rs=\(ESCLConfiguration.basePath.dropFirst())",
            "ty=\(configuration.makeAndModel)",
            "mfg=Fujitsu",
            "mdl=ScanSnap iX500",
            "note=scannerserver",
            "uuid=\(configuration.uuid)",
            "pdl=\(ESCLDocumentFormat.allCases.map(\.rawValue).joined(separator: ","))",
            "cs=color",
            "is=adf",
            "duplex=T",
        ]
    }

    public var publicationRequest: ProcessRequest {
        ProcessRequest(
            executable: "avahi-publish-service",
            arguments: [
                "--no-fail",
                configuration.serviceName,
                ESCLConfiguration.serviceType,
                String(port),
            ] + txtRecords
        )
    }
}

public actor ESCLBonjourPublisher {
    private let executor: any ProcessExecutor
    private let configuration: ESCLConfiguration
    private var publicationTask: Task<Void, Never>?

    public init(
        configuration: ESCLConfiguration,
        executor: any ProcessExecutor = FoundationProcessExecutor()
    ) {
        self.configuration = configuration
        self.executor = executor
    }

    public func start(serviceConfiguration: ScannerServerServiceConfiguration) {
        guard publicationTask == nil, configuration.bonjourEnabled else { return }
        let publication = ESCLBonjourPublication(
            configuration: configuration,
            port: serviceConfiguration.port
        )
        let executor = executor
        publicationTask = Task {
            do {
                JLog.notice(
                    "Advertising eSCL scanner \"\(publication.configuration.serviceName)\" as \(ESCLConfiguration.serviceType) on port \(publication.port)"
                )
                let result = try await executor.execute(publication.publicationRequest)
                guard !Task.isCancelled else { return }
                let diagnostic = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = "eSCL Bonjour publication stopped with status \(result.exitStatus)"
                    + (diagnostic.isEmpty ? "" : ": \(diagnostic)")
                JLog.warning("\(message)")
            } catch is CancellationError {
                return
            } catch {
                JLog.warning("eSCL Bonjour publication failed: \(error.localizedDescription)")
            }
        }
    }

    public func stop() async {
        let task = publicationTask
        publicationTask = nil
        task?.cancel()
        await task?.value
    }
}
