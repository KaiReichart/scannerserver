import Foundation

/// Renders the eSCL XML documents. Namespaces follow the HP/Mopria eSCL schema that macOS Image
/// Capture, Windows, and sane-airscan expect.
enum ESCLDocuments {
    static let scanNamespace = "http://schemas.hp.com/imaging/escl/2011/05/03"
    static let pwgNamespace = "http://www.pwg.org/schemas/2010/12/sm"
    static let contentType = "text/xml; charset=utf-8"

    static func capabilities(
        configuration: ESCLConfiguration,
        adminURI: String?,
        serialNumber: String?
    ) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerCapabilities xmlns:scan="\(scanNamespace)" xmlns:pwg="\(pwgNamespace)">
          <pwg:Version>\(ESCLConfiguration.protocolVersion)</pwg:Version>
          <pwg:MakeAndModel>\(escape(configuration.makeAndModel))</pwg:MakeAndModel>

        """
        if let serialNumber, !serialNumber.isEmpty {
            xml += "  <pwg:SerialNumber>\(escape(serialNumber))</pwg:SerialNumber>\n"
        }
        xml += "  <scan:UUID>\(escape(configuration.uuid))</scan:UUID>\n"
        if let adminURI {
            xml += "  <scan:AdminURI>\(escape(adminURI))</scan:AdminURI>\n"
        }
        xml += """
          <scan:Adf>
            <scan:AdfSimplexInputCaps>
        \(inputCaps)
            </scan:AdfSimplexInputCaps>
            <scan:AdfDuplexInputCaps>
        \(inputCaps)
            </scan:AdfDuplexInputCaps>
            <scan:FeederCapacity>\(ESCLConfiguration.feederCapacity)</scan:FeederCapacity>
            <scan:AdfOptions>
              <scan:AdfOption>Duplex</scan:AdfOption>
            </scan:AdfOptions>
          </scan:Adf>
        </scan:ScannerCapabilities>

        """
        return xml
    }

    private static var inputCaps: String {
        let formats = ESCLDocumentFormat.allCases.map { format in
            """
                        <pwg:DocumentFormat>\(format.rawValue)</pwg:DocumentFormat>
                        <scan:DocumentFormatExt>\(format.rawValue)</scan:DocumentFormatExt>
            """
        }.joined(separator: "\n")
        return """
              <scan:MinWidth>\(ESCLConfiguration.minimumWidth)</scan:MinWidth>
              <scan:MaxWidth>\(ESCLConfiguration.maximumWidth)</scan:MaxWidth>
              <scan:MinHeight>\(ESCLConfiguration.minimumHeight)</scan:MinHeight>
              <scan:MaxHeight>\(ESCLConfiguration.maximumHeight)</scan:MaxHeight>
              <scan:MaxScanRegions>1</scan:MaxScanRegions>
              <scan:SettingProfiles>
                <scan:SettingProfile>
                  <scan:ColorModes>
                    <scan:ColorMode>RGB24</scan:ColorMode>
                  </scan:ColorModes>
                  <scan:ContentTypes>
                    <pwg:ContentType>Text</pwg:ContentType>
                    <pwg:ContentType>TextAndPhoto</pwg:ContentType>
                    <pwg:ContentType>Photo</pwg:ContentType>
                  </scan:ContentTypes>
                  <scan:DocumentFormats>
        \(formats)
                  </scan:DocumentFormats>
                  <scan:SupportedResolutions>
                    <scan:DiscreteResolutions>
                      <scan:DiscreteResolution>
                        <scan:XResolution>\(ESCLConfiguration.resolution)</scan:XResolution>
                        <scan:YResolution>\(ESCLConfiguration.resolution)</scan:YResolution>
                      </scan:DiscreteResolution>
                    </scan:DiscreteResolutions>
                  </scan:SupportedResolutions>
                  <scan:ColorSpaces>
                    <scan:ColorSpace>sRGB</scan:ColorSpace>
                  </scan:ColorSpaces>
                </scan:SettingProfile>
              </scan:SettingProfiles>
              <scan:SupportedIntents>
                <scan:Intent>Document</scan:Intent>
                <scan:Intent>TextAndGraphic</scan:Intent>
                <scan:Intent>Photo</scan:Intent>
              </scan:SupportedIntents>
              <scan:MaxOpticalXResolution>\(ESCLConfiguration.resolution)</scan:MaxOpticalXResolution>
              <scan:MaxOpticalYResolution>\(ESCLConfiguration.resolution)</scan:MaxOpticalYResolution>
        """
    }

    static func status(_ snapshot: ESCLStatusSnapshot, now: Date = Date()) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerStatus xmlns:scan="\(scanNamespace)" xmlns:pwg="\(pwgNamespace)">
          <pwg:Version>\(ESCLConfiguration.protocolVersion)</pwg:Version>
          <pwg:State>\(snapshot.state.rawValue)</pwg:State>

        """
        if let adfState = snapshot.adfState {
            xml += "  <scan:AdfState>\(adfState.rawValue)</scan:AdfState>\n"
        }
        if !snapshot.jobs.isEmpty {
            xml += "  <scan:Jobs>\n"
            for job in snapshot.jobs {
                let age = max(0, Int(now.timeIntervalSince(job.created)))
                xml += """
                    <scan:JobInfo>
                      <pwg:JobUri>\(ESCLConfiguration.basePath)/ScanJobs/\(job.id)</pwg:JobUri>
                      <pwg:JobUuid>\(job.id)</pwg:JobUuid>
                      <scan:Age>\(age)</scan:Age>
                      <pwg:ImagesCompleted>\(job.imagesCompleted)</pwg:ImagesCompleted>
                      <pwg:ImagesToTransfer>\(job.imagesToTransfer)</pwg:ImagesToTransfer>
                      <pwg:JobState>\(job.state.rawValue)</pwg:JobState>
                      <pwg:JobStateReasons>
                        <pwg:JobStateReason>\(job.stateReason)</pwg:JobStateReason>
                      </pwg:JobStateReasons>
                    </scan:JobInfo>

                """
            }
            xml += "  </scan:Jobs>\n"
        }
        xml += "</scan:ScannerStatus>\n"
        return xml
    }

    static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
