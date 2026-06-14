import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class CLIWatcher {
    private let logPath = NSString(string: "~/Library/Logs/Wispr Flow/accessibility.log").expandingTildeInPath
    private let helperLogPath = NSString(string: "~/Library/Logs/Screen Sharing Paste Helper/helper.log").expandingTildeInPath
    private let historyDBPath = NSString(string: "~/Library/Application Support/Wispr Flow/flow.sqlite").expandingTildeInPath
    private var lastOffset: UInt64 = 0
    private var cycleID = 0
    private var triggeredCycleID = -1
    private var cycleStartedAt = Date.distantPast
    private var clipboardReadyCycleID = -1
    private var screenSharingCycleID = -1
    private var completedCycleID = -1
    private var expectedTextLength: Int?
    private var lastDictationStartedAt: Date?
    private var lastScreenSharingDictationStartedAt: Date?
    private var cycleDictationStartedAt: Date?
    private var lastTrigger = Date.distantPast
    private var lastWisprUIHideCheck = Date.distantPast
    private var lastWisprUIHideLog = Date.distantPast
    private var lastUsedTranscriptEntityId: String?
    private var handledTranscriptEntityIds = Set<String>()
    private let strategy: String
    private let pollIntervalMicros: useconds_t = 50_000
    private let triggerDelayMicros: useconds_t = 50_000
    private let providerPasteDelaySeconds = 0.06
    private let remoteClipboardSyncDelaySeconds = 0.85
    private let wisprUIHideIntervalSeconds: TimeInterval = 0.5
    private let deleteBeforePaste = true
    private let maxScreenSharingDictationAgeSeconds: TimeInterval = 15 * 60
    private let maxWisprLogLineAgeSeconds: TimeInterval = 90
    private let verboseLogging: Bool
    private let screenSharingBundleIdentifier = "com.apple.ScreenSharing"
    private let wisprBundleIdentifiers = [
        "com.electron.wispr-flow",
        "com.electron.wispr-flow.accessibility-mac-app"
    ]

    init(strategy: String) {
        self.strategy = strategy
        self.verboseLogging = ProcessInfo.processInfo.environment["WISPR_HELPER_VERBOSE_LOGS"] == "1"
    }

    func run() {
        setupFileLogging()
        let accessibilityTrusted = requestAccessibilityIfNeeded()
        print("Screen Sharing Paste Helper for Wispr Flow")
        print("AXIsProcessTrusted=\(accessibilityTrusted)")
        print("strategy=\(strategy)")
        print("providerPasteDelaySeconds=\(providerPasteDelaySeconds)")
        print("remoteClipboardSyncDelaySeconds=\(remoteClipboardSyncDelaySeconds)")
        print("wisprUIHideIntervalSeconds=\(wisprUIHideIntervalSeconds)")
        print("verboseLogging=\(verboseLogging)")
        print("Press Ctrl+C to stop.")
        seekToEnd()

        while true {
            autoreleasepool {
                poll()
                hideWisprUIIfScreenSharingFrontmost()
            }
            usleep(pollIntervalMicros)
        }
    }

    private func setupFileLogging() {
        let directory = (helperLogPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        freopen(helperLogPath, "a", stdout)
        freopen(helperLogPath, "a", stderr)
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        print("")
        print("---- started \(Date()) ----")
    }

    private func requestAccessibilityIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func anotherHelperInstanceIsRunning() -> Bool {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,command="]
        task.standardOutput = pipe

        do {
            try task.run()
        } catch {
            print("\(timestamp()) process check failed: \(error)")
            return false
        }

        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return false }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }

        let currentPID = String(getpid())
        let helperCommandMarkers = [
            "/Contents/MacOS/Screen Sharing Paste Helper",
            "wispr-screen-share-paste-fix"
        ]

        return output.split(separator: "\n").contains { line in
            let text = String(line)
            guard helperCommandMarkers.contains(where: { text.contains($0) }) else {
                return false
            }
            let pid = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ", maxSplits: 1)
                .first
                .map(String.init)
            return pid != currentPID
        }
    }

    private func seekToEnd() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? UInt64 else {
            lastOffset = 0
            return
        }
        lastOffset = size
    }

    private func poll() {
        guard let handle = FileHandle(forReadingAtPath: logPath) else { return }
        defer { try? handle.close() }

        let size = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? UInt64) ?? 0
        if size < lastOffset { lastOffset = 0 }
        guard size > lastOffset else { return }

        do {
            try handle.seek(toOffset: lastOffset)
            let data = try handle.readToEnd() ?? Data()
            lastOffset = try handle.offset()
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                handleLine(String(line))
            }
        } catch {
            print("log read error: \(error)")
        }
    }

    private func handleLine(_ line: String) {
        let logDate = Self.parseWisprLogDate(from: line)
        if let logDate {
            let age = Date().timeIntervalSince(logDate)
            if age > maxWisprLogLineAgeSeconds {
                logVerbose("ignored stale Wispr log line age=\(String(format: "%.1f", age))s")
                return
            }
            if age < -5 {
                logVerbose("ignored future-dated Wispr log line age=\(String(format: "%.1f", age))s")
                return
            }
        }

        if line.contains("Received IPC message: DictationStart") {
            lastDictationStartedAt = logDate ?? Date()
            return
        }

        if line.contains("Built active app info payload"),
           let startedAt = lastDictationStartedAt,
           let contextAt = logDate,
           abs(contextAt.timeIntervalSince(startedAt)) < 1.0 {
            if line.contains("bundle=com.apple.ScreenSharing") {
                lastScreenSharingDictationStartedAt = startedAt
                logVerbose("saw Screen Sharing dictation start at \(Self.dbTimestampString(from: startedAt))")
            } else {
                lastScreenSharingDictationStartedAt = nil
                logVerbose("cleared Screen Sharing dictation start for non-Screen Sharing context")
            }
            return
        }

        if line.contains("Pasting text with length:") {
            cycleID += 1
            cycleStartedAt = Date()
            clipboardReadyCycleID = -1
            screenSharingCycleID = -1
            completedCycleID = -1
            expectedTextLength = Self.parseTextLength(from: line)
            let pasteAt = logDate ?? Date()
            if let startedAt = lastScreenSharingDictationStartedAt,
               pasteAt.timeIntervalSince(startedAt) >= 0,
               pasteAt.timeIntervalSince(startedAt) <= maxScreenSharingDictationAgeSeconds {
                cycleDictationStartedAt = startedAt
            } else {
                cycleDictationStartedAt = nil
            }
            print("\(timestamp()) saw Wispr paste cycle \(cycleID)")
            return
        }

        if line.contains("currentWindowBundleId: com.apple.ScreenSharing") {
            screenSharingCycleID = cycleID
            print("\(timestamp()) saw Screen Sharing context for cycle \(cycleID)")
            maybeTrigger()
            return
        }

        if line.contains("Set up delayed clipboard rendering") {
            clipboardReadyCycleID = cycleID
            print("\(timestamp()) saw Wispr clipboard ready for cycle \(cycleID)")
            maybeTrigger()
            return
        }

        if line.contains("Completed processing PasteText") {
            completedCycleID = cycleID
            print("\(timestamp()) saw Wispr paste completed for cycle \(cycleID)")
            maybeTrigger()
        }
    }

    private func maybeTrigger() {
        let now = Date()
        guard cycleID > 0,
              clipboardReadyCycleID == cycleID,
              screenSharingCycleID == cycleID,
              completedCycleID == cycleID,
              triggeredCycleID != cycleID,
              now.timeIntervalSince(cycleStartedAt) < 2.0,
              now.timeIntervalSince(lastTrigger) > 0.25 else {
            return
        }
        triggeredCycleID = cycleID
        lastTrigger = now
        usleep(triggerDelayMicros)
        materializeClipboardThenEmitPaste()
    }

    private func materializeClipboardThenEmitPaste() {
        guard !anotherHelperInstanceIsRunning() else {
            print("\(timestamp()) skip: another helper instance is already running")
            return
        }

        guard hasAccessibilityPermission() else {
            print("\(timestamp()) skip: Accessibility permission not granted")
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<none>"
        guard frontmost == screenSharingBundleIdentifier else {
            print("\(timestamp()) skip: frontmost=\(frontmost); not Screen Sharing")
            return
        }
        hideWisprUIIfScreenSharingFrontmost(force: true)
        activateScreenSharing()

        switch strategy {
        case "exact-type":
            consumeActiveWisprClipboardProvider()
            guard let candidate = exactCurrentHistoryTranscript() else {
                print("\(timestamp()) skip: could not find exact current Wispr history text")
                return
            }
            guard !handledTranscriptEntityIds.contains(candidate.id) else {
                print("\(timestamp()) skip: transcript already handled")
                return
            }
            handledTranscriptEntityIds.insert(candidate.id)
            emitAppleScriptType(candidate.text)
        case "provider-applescript":
            print("\(timestamp()) using active Wispr delayed clipboard provider")
            emitAppleScriptPaste(delaySeconds: providerPasteDelaySeconds)
        case "cgevent-sequence":
            guard materializeCurrentWisprHistoryText() else {
                print("\(timestamp()) skip: could not materialize current Wispr history text")
                return
            }
            emitCGModifierSequencePaste()
        case "cgevent":
            guard materializeCurrentWisprHistoryText() else {
                print("\(timestamp()) skip: could not materialize current Wispr history text")
                return
            }
            emitCGFlaggedPaste()
        default:
            guard materializeCurrentWisprHistoryText() else {
                print("\(timestamp()) skip: could not materialize current Wispr history text")
                return
            }
            emitAppleScriptPaste(delaySeconds: remoteClipboardSyncDelaySeconds)
        }

        print("\(timestamp()) emitted \(strategy) paste")
    }

    private func activateScreenSharing() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: screenSharingBundleIdentifier).first else {
            return
        }
        app.activate(options: [.activateIgnoringOtherApps])
        usleep(40_000)
    }

    private func hideWisprUIIfScreenSharingFrontmost(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastWisprUIHideCheck) >= wisprUIHideIntervalSeconds else {
            return
        }
        lastWisprUIHideCheck = now

        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == screenSharingBundleIdentifier else {
            return
        }

        var hidAny = false
        for bundleIdentifier in wisprBundleIdentifiers {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) where !app.isHidden {
                hidAny = app.hide() || hidAny
            }
        }

        guard hidAny, now.timeIntervalSince(lastWisprUIHideLog) > 5 else {
            return
        }
        lastWisprUIHideLog = now
        log("hid Wispr UI while Screen Sharing was frontmost")
    }

    private func materializeCurrentWisprHistoryText() -> Bool {
        let deadline = Date().addingTimeInterval(1.2)

        while Date() < deadline {
            if let candidate = newestMatchingHistoryTranscript() {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(candidate.text, forType: .string)
                lastUsedTranscriptEntityId = candidate.id
                log("materialized history transcript")
                logVerbose("materialized history transcript length=\(candidate.text.count) timestamp=\(candidate.timestamp)")
                usleep(30_000)
                return true
            }
            usleep(50_000)
        }

        log("history transcript not found")
        logVerbose("history transcript not found expected=\(expectedTextLength.map(String.init) ?? "unknown")")
        return false
    }

    private struct HistoryTranscript {
        let id: String
        let timestamp: String
        let text: String
        let deltaSeconds: Double?
    }

    private func exactCurrentHistoryTranscript() -> HistoryTranscript? {
        guard let expectedTextLength else {
            print("\(timestamp()) exact lookup missing expected text length")
            return nil
        }
        guard let cycleDictationStartedAt else {
            print("\(timestamp()) exact lookup missing Screen Sharing dictation start")
            return nil
        }

        let startedAtString = Self.dbTimestampString(from: cycleDictationStartedAt)
        let deadline = Date().addingTimeInterval(0.8)

        while Date() < deadline {
            if let candidate = historyTranscript(startedNear: startedAtString, expectedTextLength: expectedTextLength) {
                lastUsedTranscriptEntityId = candidate.id
                let delta = candidate.deltaSeconds.map { String(format: "%.3f", $0) } ?? "unknown"
                log("exact history transcript found")
                logVerbose("exact history transcript length=\(candidate.text.count) timestamp=\(candidate.timestamp) delta=\(delta)s")
                return candidate
            }
            usleep(30_000)
        }

        log("exact history transcript not found")
        logVerbose("exact history transcript not found start=\(startedAtString) expected=\(expectedTextLength)")
        return nil
    }

    private func historyTranscript(startedNear startedAtString: String, expectedTextLength: Int) -> HistoryTranscript? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(historyDBPath, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        let sql = """
        SELECT transcriptEntityId,
               timestamp,
               COALESCE(NULLIF(pastedText, ''), NULLIF(formattedText, ''), NULLIF(asrText, '')) AS text,
               ABS((julianday(timestamp) - julianday(?1)) * 86400.0) AS deltaSeconds
        FROM History
        WHERE app = 'com.apple.ScreenSharing'
          AND COALESCE(NULLIF(pastedText, ''), NULLIF(formattedText, ''), NULLIF(asrText, '')) IS NOT NULL
          AND ABS((julianday(timestamp) - julianday(?1)) * 86400.0) < 3.0
        ORDER BY deltaSeconds ASC
        LIMIT 10
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, startedAtString, -1, SQLITE_TRANSIENT)

        var nearestCandidate: HistoryTranscript?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let timestampPointer = sqlite3_column_text(statement, 1),
                  let textPointer = sqlite3_column_text(statement, 2) else {
                continue
            }

            let text = Self.plainTextForTyping(String(cString: textPointer))
            let transcript = HistoryTranscript(
                id: String(cString: idPointer),
                timestamp: String(cString: timestampPointer),
                text: text,
                deltaSeconds: sqlite3_column_double(statement, 3)
            )

            if Self.matchesExpectedLength(text, expectedTextLength) {
                return transcript
            }

            if nearestCandidate == nil {
                nearestCandidate = transcript
            }
        }

        if let nearestCandidate,
           let delta = nearestCandidate.deltaSeconds,
           delta < 0.35 {
            log("accepting nearest timestamp despite length mismatch")
            logVerbose("accepting nearest timestamp despite length mismatch actual=\(nearestCandidate.text.count) expected=\(expectedTextLength)")
            return nearestCandidate
        }

        return nil
    }

    private func newestMatchingHistoryTranscript() -> HistoryTranscript? {
        guard let expectedTextLength else { return nil }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(historyDBPath, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        let sql = """
        SELECT transcriptEntityId,
               timestamp,
               COALESCE(NULLIF(pastedText, ''), NULLIF(formattedText, ''), NULLIF(asrText, '')) AS text
        FROM History
        WHERE app = 'com.apple.ScreenSharing'
          AND COALESCE(NULLIF(pastedText, ''), NULLIF(formattedText, ''), NULLIF(asrText, '')) IS NOT NULL
        ORDER BY timestamp DESC
        LIMIT 50
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let timestampPointer = sqlite3_column_text(statement, 1),
                  let textPointer = sqlite3_column_text(statement, 2) else {
                continue
            }

            let id = String(cString: idPointer)
            if id == lastUsedTranscriptEntityId { continue }

            let text = Self.plainTextForTyping(String(cString: textPointer))
            guard Self.matchesExpectedLength(text, expectedTextLength) else { continue }

            return HistoryTranscript(
                id: id,
                timestamp: String(cString: timestampPointer),
                text: text,
                deltaSeconds: nil
            )
        }

        return nil
    }

    private func consumeActiveWisprClipboardProvider() {
        let text = NSPasteboard.general.string(forType: .string)
        log("requested active Wispr provider")
        logVerbose("requested active Wispr provider length=\(text?.count ?? -1)")
    }

    private func emitAppleScriptType(_ text: String) {
        let normalized = Self.plainTextForTyping(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var commands: [String] = [
            "tell application \"Screen Sharing\" to activate",
            "delay 0.04",
            "tell application \"System Events\""
        ]

        if deleteBeforePaste {
            commands.append("  key code 51")
            commands.append("  delay 0.03")
        }

        let lines = normalized.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            for chunk in Self.chunks(line, size: 160) where !chunk.isEmpty {
                commands.append("  keystroke \(Self.appleScriptStringLiteral(chunk))")
                commands.append("  delay 0.005")
            }
            if lineIndex < lines.count - 1 {
                commands.append("  key code 36 using shift down")
                commands.append("  delay 0.005")
            }
        }

        commands.append("end tell")

        var error: NSDictionary?
        NSAppleScript(source: commands.joined(separator: "\n"))?.executeAndReturnError(&error)
        if let error {
            print("\(timestamp()) AppleScript type error: \(error)")
        }
    }

    private func emitAppleScriptPaste(delaySeconds: Double) {
        let script: String
        if deleteBeforePaste {
            script = """
            tell application "Screen Sharing" to activate
            delay 0.04
            tell application "System Events"
              key code 51
              delay \(delaySeconds)
              key code 9 using command down
            end tell
            """
        } else {
            script = """
            tell application "Screen Sharing" to activate
            delay \(delaySeconds)
            tell application "System Events"
              key code 9 using command down
            end tell
            """
        }
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            print("\(timestamp()) AppleScript error: \(error)")
        }
    }

    private func emitCGFlaggedPaste() {
        if deleteBeforePaste {
            emitBackspace()
            usleep(10_000)
        }
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(40_000)
        up?.post(tap: .cghidEventTap)
    }

    private func emitCGModifierSequencePaste() {
        if deleteBeforePaste {
            emitBackspace()
            usleep(10_000)
        }
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        let commandKey = CGKeyCode(kVK_Command)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false)
        commandDown?.flags = .maskCommand
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        commandUp?.flags = []
        commandDown?.post(tap: .cghidEventTap)
        usleep(30_000)
        vDown?.post(tap: .cghidEventTap)
        usleep(40_000)
        vUp?.post(tap: .cghidEventTap)
        usleep(30_000)
        commandUp?.post(tap: .cghidEventTap)
    }

    private func emitBackspace() {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        let key = CGKeyCode(kVK_Delete)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.post(tap: .cghidEventTap)
        usleep(20_000)
        up?.post(tap: .cghidEventTap)
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private func log(_ message: String) {
        print("\(timestamp()) \(message)")
    }

    private func logVerbose(_ message: String) {
        if verboseLogging {
            log(message)
        }
    }

    private static func parseTextLength(from line: String) -> Int? {
        guard let markerRange = line.range(of: "Pasting text with length:") else { return nil }
        let suffix = line[markerRange.upperBound...]
        let digits = suffix.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return Int(digits)
    }

    private static func parseWisprLogDate(from line: String) -> Date? {
        guard line.first == "[",
              let closingBracket = line.firstIndex(of: "]") else {
            return nil
        }
        let raw = String(line[line.index(after: line.startIndex)..<closingBracket])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: raw)
    }

    private static func dbTimestampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS XXX"
        return formatter.string(from: date)
    }

    private static func matchesExpectedLength(_ text: String, _ expected: Int) -> Bool {
        text.count == expected || text.utf16.count == expected
    }

    private static func plainTextForTyping(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        guard looksLikeGeneratedHTML(normalized) else {
            return decodeHTMLEntities(normalized)
        }

        var result = normalized
        result = replacingPattern("(?i)<\\s*br\\s*/?\\s*>", in: result, with: "\n")
        result = replacingPattern("(?i)</?\\s*(ol|ul|li|p|div|blockquote|h[1-6])\\b[^>]*>", in: result, with: "\n")
        result = replacingPattern("(?s)<[^>]+>", in: result, with: "")
        result = decodeHTMLEntities(result)

        let lines = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }

    private static func looksLikeGeneratedHTML(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return [
            "<ol", "</ol",
            "<ul", "</ul",
            "<li", "</li",
            "<p", "</p",
            "<div", "</div",
            "<br"
        ].contains { lowercased.contains($0) }
    }

    private static func replacingPattern(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let namedEntities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'"
        ]

        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        guard let regex = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);") else {
            return result
        }

        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let valueRange = Range(match.range(at: 1), in: result) else {
                continue
            }

            let rawValue = String(result[valueRange])
            let scalarValue: UInt32?
            if rawValue.lowercased().hasPrefix("x") {
                scalarValue = UInt32(rawValue.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(rawValue, radix: 10)
            }

            if let scalarValue, let scalar = UnicodeScalar(scalarValue) {
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        return result
    }

    private static func chunks(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }

    private static func appleScriptStringLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

let strategy = CommandLine.arguments.dropFirst().first ?? "exact-type"
setbuf(stdout, nil)
setbuf(stderr, nil)
CLIWatcher(strategy: strategy).run()
