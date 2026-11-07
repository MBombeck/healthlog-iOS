#if DEBUG
    import Foundation

    /// **LAB-OCR (1.5.0, #149 item 3) — the server read of a lab report,
    /// photographed.**
    ///
    /// Under `-uitest-lab-ocr` the scan sheet treats the server read as offered
    /// (vision, PDF accepted) without asking the network or the consent store,
    /// so the chooser with "Genauer lesen lassen" can be photographed. Under
    /// `-uitest-lab-ocr-review` as well, the sheet opens straight on the review
    /// list of an invented two-page report whose read ran into limits: page 2
    /// cut, page 3 not read, the budget stopped it, and a "1" read as a unit.
    /// Everything is invented; no value of any real person appears here.
    enum LabOCRFixtures {
        static let argument = "-uitest-lab-ocr"
        static let reviewArgument = "-uitest-lab-ocr-review"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        static var opensOnReview: Bool {
            isActive && ProcessInfo.processInfo.arguments.contains(reviewArgument)
        }

        static let capability = LabsOCRCapability(available: true, mode: .vision, pdfSupported: true)

        static let result = LabsOCRExtractResult(
            reportDate: "2026-10-28",
            rows: [
                LabsOCRRow(
                    analyte: "Ferritin", value: 42, unit: "ng/ml", referenceLow: 30, referenceHigh: 400,
                    referenceText: "30 - 400"
                ),
                LabsOCRRow(
                    analyte: "INR", value: 1.1, unit: "1", referenceLow: 0.85, referenceHigh: 1.15,
                    referenceText: "0,85 - 1,15"
                ),
                LabsOCRRow(analyte: "Nitrit", valueText: "negativ", referenceText: "negativ")
            ],
            truncatedPages: [2],
            unreadPages: [3],
            stoppedBy: .budget
        )
    }
#endif
