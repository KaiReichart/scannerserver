import Foundation
import Hummingbird

/// Driverless-scanning (eSCL / AirScan) adapter. Registered only when `SCAN_ESCL_ENABLED` is set.
///
/// The client pulls a scan: `POST /eSCL/ScanJobs` starts an acquisition and returns the job URL,
/// then `GET …/NextDocument` is polled until it returns 404. JPEG jobs stream one side per request
/// while the feeder is still running; PDF jobs return one document once acquisition finishes.
package func registerESCLRoutes(
    _ router: Router<BasicRequestContext>,
    dependencies: ScannerServerDependencies
) {
    guard let service = dependencies.escl else { return }
    let base = ESCLConfiguration.basePath

    @Sendable func scannerAvailability() async -> (available: Bool, setup: ScannerSetupState) {
        let setup = await dependencies.scannerSetup.state()
        let wifiBackend = dependencies.environment["SCAN_BACKEND", default: "wifi"] == "wifi"
        return (wifiBackend && setup.configured, setup)
    }

    router.get("\(base)/ScannerCapabilities") { request, _ -> Response in
        let setup = await dependencies.scannerSetup.state()
        let xml = ESCLDocuments.capabilities(
            configuration: service.configuration,
            adminURI: request.head.authority.map { "http://\($0)/" },
            serialNumber: setup.serial
        )
        return esclResponse(Data(xml.utf8), contentType: ESCLDocuments.contentType)
    }

    router.get("\(base)/ScannerStatus") { _, _ -> Response in
        let availability = await scannerAvailability()
        let busy = await dependencies.scanJobs.state.status == "running"
        let snapshot = await service.statusSnapshot(
            scannerAvailable: availability.available,
            scannerBusy: busy
        )
        return esclResponse(Data(ESCLDocuments.status(snapshot).utf8), contentType: ESCLDocuments.contentType)
    }

    router.post("\(base)/ScanJobs") { request, _ -> Response in
        let availability = await scannerAvailability()
        guard availability.available else {
            return esclText(
                "The ScanSnap Wi-Fi scanner is not configured; finish setup in the web UI.",
                status: .serviceUnavailable
            )
        }

        let settings: ESCLScanSettings
        do {
            let body = try await request.body.collect(upTo: 64 * 1_024)
            settings = try ESCLScanSettings(xml: Data(buffer: body))
        } catch let error as ESCLScanSettingsError {
            switch error {
            case .malformedXML:
                return esclText(error.localizedDescription, status: .badRequest)
            case .unsupportedInputSource, .unsupportedDocumentFormat:
                return esclText(error.localizedDescription, status: .conflict)
            }
        } catch {
            return esclText("Could not read ScanSettings: \(error.localizedDescription)", status: .badRequest)
        }

        var environment = dependencies.environment
        environment.merge(availability.setup.scannerEnvironment) { _, configured in configured }
        switch await service.startJob(settings: settings, scanEnvironment: environment) {
        case .created(let id):
            let path = "\(base)/ScanJobs/\(id)"
            let location = request.head.authority.map { "http://\($0)\(path)" } ?? path
            return Response(
                status: .created,
                headers: [.location: location, .contentLength: "0"]
            )
        case .busy:
            return esclText(
                "The scanner is busy with another scan.",
                status: .serviceUnavailable,
                additionalHeaders: [.retryAfter: "5"]
            )
        case .failed(let message):
            return esclText(message, status: .internalServerError)
        }
    }

    router.get("\(base)/ScanJobs/:job/NextDocument") { _, context -> Response in
        guard let jobID = context.parameters.get("job") else {
            return esclText("Unknown scan job.", status: .notFound)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: service.configuration.nextDocumentTimeout)
        while true {
            switch await service.nextDocument(jobID: jobID) {
            case .document(let data, let contentType):
                return esclResponse(data, contentType: contentType)
            case .finished, .unknownJob:
                return esclText("No more documents.", status: .notFound)
            case .pending:
                guard clock.now < deadline else {
                    return esclText(
                        "The next page is not ready yet.",
                        status: .serviceUnavailable,
                        additionalHeaders: [.retryAfter: "1"]
                    )
                }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    router.delete("\(base)/ScanJobs/:job") { _, context -> Response in
        guard let jobID = context.parameters.get("job"),
              await service.cancel(jobID: jobID) else {
            return esclText("Unknown scan job.", status: .notFound)
        }
        return Response(status: .ok, headers: [.contentLength: "0"])
    }
}

private func esclResponse(
    _ data: Data,
    status: HTTPResponse.Status = .ok,
    contentType: String,
    additionalHeaders: HTTPFields = [:]
) -> Response {
    let buffer = ByteBuffer(bytes: data)
    var headers = additionalHeaders
    headers[.contentType] = contentType
    headers[.contentLength] = "\(buffer.readableBytes)"
    headers[.cacheControl] = "no-store"
    return Response(status: status, headers: headers, body: .init(byteBuffer: buffer))
}

private func esclText(
    _ text: String,
    status: HTTPResponse.Status,
    additionalHeaders: HTTPFields = [:]
) -> Response {
    esclResponse(
        Data((text + "\n").utf8),
        status: status,
        contentType: "text/plain; charset=utf-8",
        additionalHeaders: additionalHeaders
    )
}
