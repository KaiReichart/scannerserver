import Foundation
import JLog

public enum ESCLScannerState: String, Equatable, Sendable {
    case idle = "Idle"
    case processing = "Processing"
    case stopped = "Stopped"
}

public enum ESCLAdfState: String, Equatable, Sendable {
    case processing = "ScannerAdfProcessing"
    case empty = "ScannerAdfEmpty"
    case loaded = "ScannerAdfLoaded"
}

public enum ESCLJobState: String, Equatable, Sendable {
    case pending = "Pending"
    case processing = "Processing"
    case completed = "Completed"
    case canceled = "Canceled"
    case aborted = "Aborted"

    var isTerminal: Bool {
        switch self {
        case .pending, .processing: false
        case .completed, .canceled, .aborted: true
        }
    }
}

public struct ESCLJobSnapshot: Equatable, Sendable {
    public let id: String
    public let created: Date
    public let state: ESCLJobState
    public let stateReason: String
    public let imagesCompleted: Int
    public let imagesToTransfer: Int
}

public struct ESCLStatusSnapshot: Equatable, Sendable {
    public let state: ESCLScannerState
    public let adfState: ESCLAdfState?
    public let jobs: [ESCLJobSnapshot]
}

public enum ESCLStartJobOutcome: Equatable, Sendable {
    case created(id: String)
    case busy
    case failed(String)
}

public enum ESCLNextDocument: Equatable, Sendable {
    case document(Data, contentType: String)
    case pending
    case finished
    case unknownJob
}

/// Owns driverless (eSCL) scan jobs.
///
/// Every eSCL acquisition runs through `ScanJobActor`, so it shares the single-flight guard with
/// web and physical-button scans and the physical-button session is handed off and resumed exactly
/// as it is for a web scan. Pages are buffered in memory only until the client pulls them with
/// `NextDocument`; eSCL scans are not published to the scan directory.
public actor ESCLScanService {
    private struct Job {
        let id: String
        let created: Date
        let settings: ESCLScanSettings
        let workDirectory: URL
        var state: ESCLJobState = .pending
        var stateReason = "JobQueued"
        var cancelRequested = false
        var pendingPages: [Data] = []
        var deliveredImages = 0
        var acquiredImages = 0
        var pdfURL: URL?
        var finished: Date?

        var snapshot: ESCLJobSnapshot {
            let toTransfer: Int
            switch settings.documentFormat {
            case .jpeg: toTransfer = pendingPages.count
            case .pdf: toTransfer = pdfURL == nil ? 0 : 1
            }
            return ESCLJobSnapshot(
                id: id,
                created: created,
                state: state,
                stateReason: stateReason,
                imagesCompleted: acquiredImages,
                imagesToTransfer: toTransfer
            )
        }
    }

    public nonisolated let configuration: ESCLConfiguration
    private let scanJobs: ScanJobActor
    private let acquisitionSessions: ScanSnapAcquisitionSessionCoordinator
    private let acquirer: any ScanSnapWiFiAcquiring
    private let workDirectoryRoot: URL
    private var jobs: [String: Job] = [:]
    private var jobOrder: [String] = []
    private var activeJobID: String?
    /// When the last acquisition found no paper. The iX500 cannot report its paper sensor without
    /// taking over the button session, so idle status optimistically reports a loaded feeder and
    /// reports it empty only briefly after a scan proved it, long enough for the client that
    /// started the job to read it but not so long that clients refuse to start the next scan.
    private var feederReportedEmptyAt: Date?
    private static let emptyFeederReportWindow: TimeInterval = 15

    public init(
        configuration: ESCLConfiguration,
        scanJobs: ScanJobActor,
        acquisitionSessions: ScanSnapAcquisitionSessionCoordinator,
        acquirer: any ScanSnapWiFiAcquiring = ScanSnapWiFiAcquisitionClient(),
        workDirectoryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.configuration = configuration
        self.scanJobs = scanJobs
        self.acquisitionSessions = acquisitionSessions
        self.acquirer = acquirer
        self.workDirectoryRoot = workDirectoryRoot
    }

    // MARK: Job lifecycle

    public func startJob(
        settings: ESCLScanSettings,
        scanEnvironment: [String: String]
    ) async -> ESCLStartJobOutcome {
        pruneExpiredJobs()
        guard activeJobID == nil else { return .busy }

        let id = UUID().uuidString.lowercased()
        let workDirectory = workDirectoryRoot.appendingPathComponent(
            "scannerserver-escl.\(id)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return .failed("Could not create eSCL work directory: \(error.localizedDescription)")
        }

        jobs[id] = Job(id: id, created: Date(), settings: settings, workDirectory: workDirectory)
        jobOrder.append(id)
        activeJobID = id

        let started = await scanJobs.start(trigger: .escl) { [self] in
            try await self.runAcquisition(jobID: id, scanEnvironment: scanEnvironment)
        }
        guard started else {
            removeJob(id)
            activeJobID = nil
            return .busy
        }
        JLog.notice(
            "Started eSCL scan job \(id) (\(settings.duplex ? "duplex" : "simplex"), \(settings.documentFormat.rawValue))"
        )
        return .created(id: id)
    }

    public func nextDocument(jobID: String) -> ESCLNextDocument {
        guard var job = jobs[jobID] else { return .unknownJob }

        switch job.settings.documentFormat {
        case .jpeg:
            if !job.pendingPages.isEmpty {
                let page = job.pendingPages.removeFirst()
                job.deliveredImages += 1
                jobs[jobID] = job
                return .document(page, contentType: ESCLDocumentFormat.jpeg.rawValue)
            }
            return job.state.isTerminal ? .finished : .pending

        case .pdf:
            if let pdfURL = job.pdfURL {
                job.pdfURL = nil
                jobs[jobID] = job
                defer { try? FileManager.default.removeItem(at: job.workDirectory) }
                do {
                    let data = try Data(contentsOf: pdfURL)
                    job.deliveredImages += 1
                    jobs[jobID] = job
                    return .document(data, contentType: ESCLDocumentFormat.pdf.rawValue)
                } catch {
                    JLog.warning("Could not read eSCL PDF for job \(jobID): \(error.localizedDescription)")
                    return .finished
                }
            }
            return job.state.isTerminal ? .finished : .pending
        }
    }

    /// Cancels a job. Returns `false` when the job is unknown.
    public func cancel(jobID: String) async -> Bool {
        guard var job = jobs[jobID] else { return false }
        guard !job.state.isTerminal else {
            // Clients commonly DELETE a finished job to release it.
            removeJob(jobID)
            return true
        }
        job.cancelRequested = true
        let wasProcessing = job.state == .processing
        jobs[jobID] = job
        if wasProcessing, activeJobID == jobID {
            await scanJobs.cancel()
        }
        return true
    }

    public func statusSnapshot(scannerAvailable: Bool, scannerBusy: Bool) -> ESCLStatusSnapshot {
        pruneExpiredJobs()
        let state: ESCLScannerState
        if !scannerAvailable {
            state = .stopped
        } else if activeJobID != nil || scannerBusy {
            state = .processing
        } else {
            state = .idle
        }
        let adfState: ESCLAdfState?
        if activeJobID != nil {
            adfState = .processing
        } else if let reportedAt = feederReportedEmptyAt,
                  Date().timeIntervalSince(reportedAt) < Self.emptyFeederReportWindow {
            adfState = .empty
        } else {
            adfState = .loaded
        }
        let snapshots = jobOrder.reversed().compactMap { jobs[$0]?.snapshot }
        return ESCLStatusSnapshot(state: state, adfState: adfState, jobs: snapshots)
    }

    public func job(id: String) -> ESCLJobSnapshot? {
        jobs[id]?.snapshot
    }

    // MARK: Acquisition (runs inside the ScanJobActor worker task)

    private func runAcquisition(
        jobID: String,
        scanEnvironment: [String: String]
    ) async throws -> ScanJobOperationResult {
        guard let job = jobs[jobID] else { throw CancellationError() }
        if job.cancelRequested {
            finishJob(jobID, state: .canceled, reason: "JobCanceledByUser")
            throw CancellationError()
        }
        feederReportedEmptyAt = nil
        update(jobID) {
            $0.state = .processing
            $0.stateReason = "JobScanning"
        }

        let rawPDF = job.workDirectory.appendingPathComponent("raw.pdf", isDirectory: false)
        do {
            let sessionMode = await acquisitionSessions.consumeForAcquisition()
            let request = try ScanSnapWiFiAcquisitionRequest(
                scanEnvironment: scanEnvironment,
                simplex: !job.settings.duplex,
                reusesArmedSession: sessionMode == .reuseArmed,
                outputURL: rawPDF
            )
            let streamsPages = job.settings.documentFormat == .jpeg
            let result = try await acquirer.acquire(request) { [self] page in
                await self.receive(page: page, jobID: jobID, buffer: streamsPages)
            }
            update(jobID) {
                $0.acquiredImages = result.pageCount
                if !streamsPages { $0.pdfURL = rawPDF }
            }
            finishJob(jobID, state: .completed, reason: "JobCompletedSuccessfully")
            return ScanJobOperationResult(
                succeeded: true,
                output: "eSCL scan acquired \(result.pageCount) page(s)."
            )
        } catch is CancellationError {
            finishJob(jobID, state: .canceled, reason: "JobCanceledByUser")
            throw CancellationError()
        } catch {
            if let acquisitionError = error as? ScanSnapAcquisitionError,
               acquisitionError == .noDocument || acquisitionError == .noPages {
                feederReportedEmptyAt = Date()
            }
            finishJob(jobID, state: .aborted, reason: "AbortedBySystem")
            return ScanJobOperationResult(succeeded: false, error: error.localizedDescription)
        }
    }

    private func receive(page: ScanSnapAcquiredPage, jobID: String, buffer: Bool) {
        update(jobID) {
            $0.acquiredImages = page.pageNumber
            guard buffer, !$0.cancelRequested else { return }
            $0.pendingPages.append(page.jpegData)
        }
    }

    // MARK: Bookkeeping

    private func update(_ jobID: String, _ change: (inout Job) -> Void) {
        guard var job = jobs[jobID] else { return }
        change(&job)
        jobs[jobID] = job
    }

    private func finishJob(_ jobID: String, state: ESCLJobState, reason: String) {
        update(jobID) {
            $0.state = state
            $0.stateReason = reason
            $0.finished = Date()
            if state != .completed {
                $0.pendingPages.removeAll()
                $0.pdfURL = nil
            }
        }
        if activeJobID == jobID { activeJobID = nil }
        if let job = jobs[jobID], job.pdfURL == nil {
            try? FileManager.default.removeItem(at: job.workDirectory)
        }
    }

    private func removeJob(_ jobID: String) {
        if let job = jobs.removeValue(forKey: jobID) {
            try? FileManager.default.removeItem(at: job.workDirectory)
        }
        jobOrder.removeAll { $0 == jobID }
    }

    /// Drops finished jobs once their retention expires (including undelivered pages of clients
    /// that went away) and keeps at most ten finished jobs listed in `ScannerStatus`.
    private func pruneExpiredJobs(now: Date = Date()) {
        let retention = configuration.completedJobRetention
        let retentionSeconds = Double(retention.components.seconds)
            + Double(retention.components.attoseconds) / 1e18
        let expired = jobs.values.filter { job in
            guard let finished = job.finished else { return false }
            return now.timeIntervalSince(finished) > retentionSeconds
        }
        for job in expired { removeJob(job.id) }

        let finished = jobOrder.filter { jobs[$0]?.state.isTerminal == true }
        if finished.count > 10 {
            for id in finished.prefix(finished.count - 10) { removeJob(id) }
        }
    }
}
