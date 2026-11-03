#if DEBUG
    import Foundation

    /// **iOS 1.4 B2-b — a cycle to photograph.**
    ///
    /// The marketing world answers no cycle route, so the cycle screen only
    /// ever showed its load error. Under `-uitest-area-meds` this table serves
    /// six regular cycles: the open one started nine days ago (day 10,
    /// follicular), the server's verdict and calendar prediction for it, two
    /// cycles of basal temperature, the cycle stats and two phase comparisons
    /// with one symptom pattern. Dates are relative to today in the account
    /// zone, so the screen reads the same on any day. Everything is invented;
    /// no value of any real person appears here.
    enum AreaCycleFixtures {
        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard method == "GET", path.hasPrefix("/api/cycle/") else { return nil }
            return switch path {
            case "/api/cycle/calendar": envelope(calendar())
            case "/api/cycle/cycles": envelope(cycles())
            case "/api/cycle/profile": envelope(profile)
            case "/api/cycle/insights": envelope(insights)
            case "/api/cycle/symptoms/custom": envelope(#"{"symptoms":[]}"#)
            case "/api/cycle/day-logs": envelope("null")
            default: nil
            }
        }

        // MARK: - Shape

        /// Offsets from today of the six cycle starts, newest first; the
        /// newest is the open cycle.
        private static let starts = [-9, -37, -66, -93, -121, -150]
        private static let nextStart = 19
        private static let fertileWindow = 2 ... 7
        private static let ovulation = 5

        private static func day(_ offset: Int) -> String {
            ProfileDay.key(CycleCalendarWindow.todayKey(), addingDays: offset)
        }

        private static func envelope(_ data: String) -> (Int, Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        private static func phase(cycleDay: Int) -> String {
            switch cycleDay {
            case ...5: "MENSTRUAL"
            case 6 ... 12: "FOLLICULAR"
            case 13 ... 15: "OVULATORY"
            default: "LUTEAL"
            }
        }

        // MARK: - Calendar

        private static func calendar() -> String {
            let verdict = """
            {"state":"IN_CYCLE","dayOfCycle":10,"cycleLength":28,"phase":"FOLLICULAR",\
            "spans":[{"phase":"MENSTRUAL","fraction":0.18},{"phase":"FOLLICULAR","fraction":0.25},\
            {"phase":"OVULATORY","fraction":0.11},{"phase":"LUTEAL","fraction":0.46}],\
            "cycleStartDate":"\(day(starts[0]))","overdueDays":null,"daysUntilNext":\(nextStart),\
            "fertileWindow":{"start":"\(day(fertileWindow.lowerBound))","end":"\(day(fertileWindow.upperBound))","active":false}}
            """
            let prediction = """
            {"method":"CALENDAR","nextPeriodStart":"\(day(nextStart))","nextPeriodStartLow":"\(day(nextStart - 2))",\
            "nextPeriodStartHigh":"\(day(nextStart + 2))","fertileWindowStart":"\(day(fertileWindow.lowerBound))",\
            "fertileWindowEnd":"\(day(fertileWindow.upperBound))","predictedOvulation":"\(day(ovulation))",\
            "ovulationConfirmed":false,"confidence":0.7,"cyclesObserved":5,"stillLearning":false,"disclaimer":""}
            """
            let days = (-75 ... 35).map(calendarDay).joined(separator: ",")
            return """
            {"profile":{"goal":"GENERAL_HEALTH","rawChartMode":false,"predictionEnabled":true,"cyclesObserved":5},\
            "prediction":\(prediction),"verdict":\(verdict),"stillLearning":false,"days":[\(days)]}
            """
        }

        private static func calendarDay(_ offset: Int) -> String {
            let predicted = offset >= nextStart
            let start = starts.first { $0 <= offset } ?? starts[starts.count - 1]
            let cycleDay = predicted ? offset - nextStart + 1 : offset - start + 1
            let past = offset <= 0
            let logged = past && cycleDay <= 5
            let flows = ["MEDIUM", "HEAVY", "MEDIUM", "LIGHT", "SPOTTING"]
            let flow = logged ? "\"\(flows[cycleDay - 1])\"" : "null"
            // Two cycles of waking temperature: low before ovulation, higher after.
            let wobble = Double((offset * 37 % 7 + 7) % 7 - 3) * 0.03
            let temperature = past && offset >= starts[1]
                ? String(format: "%.2f", (cycleDay >= 16 ? 36.72 : 36.38) + wobble)
                : "null"
            return """
            {"date":"\(day(offset))","phase":"\(phase(cycleDay: cycleDay))",\
            "isPredictedPeriod":\(predicted && cycleDay <= 5),"isFertileWindow":\(fertileWindow.contains(offset)),\
            "isPredictedOvulation":\(offset == ovulation),"isPeriodLogged":\(logged),\
            "isCycleStart":\(past && cycleDay == 1),"cycleDay":\(predicted ? "null" : String(cycleDay)),\
            "periodEndable":\(past && offset >= starts[0] && cycleDay <= 10),"flow":\(flow),\
            "hasSymptoms":\(logged && cycleDay <= 2),"confidence":0.7,"basalBodyTempC":\(temperature),\
            "temperatureExcluded":false,"ovulationTest":null,"cervicalMucus":null,"cervixPosition":null,\
            "cervixFirmness":null,"cervixOpening":null}
            """
        }

        // MARK: - Cycles, profile, insights

        private static func cycles() -> String {
            let rows = starts.enumerated().map { index, start in
                let open = index == 0
                let length = open ? nil : starts[index - 1] - start
                return """
                {"id":"area-cycle-\(index)","startDate":"\(day(start))",\
                "endDate":\(length.map { "\"\(day(start + $0 - 1))\"" } ?? "null"),\
                "periodEndDate":"\(day(start + 4))","lengthDays":\(length.map(String.init) ?? "null"),\
                "ovulationDate":\(open ? "null" : "\"\(day(start + 14))\""),"ovulationConfirmed":false,\
                "isPredicted":false,"syncVersion":1}
                """
            }
            return """
            {"cycles":[\(rows.joined(separator: ","))],"stats":{"avgLengthDays":28,\
            "lengthVariabilityDays":1.1,"avgPeriodLengthDays":5,"regularity":"REGULAR"}}
            """
        }

        private static let profile = """
        {"goal":"GENERAL_HEALTH","cycleTrackingEnabled":true,"rawChartMode":false,"predictionEnabled":true,\
        "discreetNotifications":false,"sensitiveCategoryEncryption":false,"typicalCycleLength":null,\
        "typicalPeriodLength":null,"lutealPhaseLength":null,"secondarySymptom":"MUCUS"}
        """

        private static let restingHeartRate = """
        {"metricKey":"restingHeartRate","display":"bpm","lutealDays":61,"follicularDays":58,\
        "lutealAvg":62.4,"follicularAvg":59.9,"delta":2.5,"pValue":0.003,"qValue":0.02,"confidence":"medium"}
        """

        private static let insights = """
        {"rows":[\(restingHeartRate),{"metricKey":"sleepDuration","display":"hours","lutealDays":63,\
        "follicularDays":60,"lutealAvg":6.9,"follicularAvg":7.3,"delta":-0.4,"pValue":0.01,"qValue":0.04,\
        "confidence":"low"}],"headline":\(restingHeartRate),"symptomPatterns":[{"symptomKey":"cramps",\
        "counts":{"menstrual":9,"follicular":1,"ovulatory":0,"luteal":2},"total":12,"topPhase":"MENSTRUAL",\
        "topShare":0.75}],"contrast":{"high":"LUTEAL","low":"FOLLICULAR"},"windowDays":365,"cyclesObserved":5}
        """
    }
#endif
