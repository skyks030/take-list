import XCTest
@testable import TakeListCore

final class CoreTests: XCTestCase {
    func testTimecodeParsing() {
        let tc = Timecode(fps: 25)
        XCTAssertEqual(tc.parse("01:00:10:00")?.frames, 3610 * 25)
        XCTAssertEqual(tc.parse("01:00:10:24")?.frames, 3610 * 25 + 24)
        XCTAssertNil(tc.parse("01:00:10:25"))
        XCTAssertEqual(tc.parse("00:00:01.500")?.frames, 25 + 13)
        XCTAssertEqual(tc.parse("00:00:02")?.style, .seconds)
        XCTAssertEqual(tc.parse(Cell(.number(1.0 / 24)))?.frames, 3600 * 25)
        XCTAssertEqual(tc.string(3610 * 25 + 5, style: .frames(separator: ":")), "01:00:10:05")
        let r = tc.parseRange(Cell(.string("01:00:00:00 - 01:00:05:00")))
        XCTAssertEqual(r?.outF, (3605) * 25)
    }

    func testSentenceSplitting() {
        let s = TextSplitter.sentences("Hallo Anna. Wie geht es dir, z.B. heute? Am 3. Mai war ich da! (lacht) Gut so.")
        XCTAssertEqual(s, ["Hallo Anna.", "Wie geht es dir, z.B. heute?", "Am 3. Mai war ich da!", "(lacht) Gut so."])
    }

    func testWordCount() {
        XCTAssertEqual(TextSplitter.wordCount("(lacht) Ja, so - ist das.", ignoreDirections: true), 4)
        XCTAssertEqual(TextSplitter.wordCount("(lacht) Ja, so - ist das.", ignoreDirections: false), 5)
    }

    func testPartitionBalanced() {
        let r = TextSplitter.partition([5, 5, 5, 5, 5, 5], into: 3)
        XCTAssertEqual(r, [0..<2, 2..<4, 4..<6])
        XCTAssertEqual(TextSplitter.minimalGroups([10, 10, 10, 10], cap: 25), 2)
    }

    func testDistributeStaysInsideOriginal() {
        var settings = ScanSettings()
        settings.fps = 25
        let chunks = ["eins zwei drei vier.", "fünf sechs.", "sieben acht neun zehn elf zwölf."]
        let t = Scanner.distribute(inF: 1000, outF: 1500, chunks: chunks, quantum: 1, gap: 0, settings: settings)!
        XCTAssertEqual(t.first?.0, 1000)
        XCTAssertEqual(t.last?.1, 1500)
        for i in 1..<t.count { XCTAssertEqual(t[i].0, t[i - 1].1) }
        XCTAssertEqual(t[0].1 - t[0].0, 167) // 4/12 of 500
    }

    func testRoleSpelling() {
        XCTAssertTrue(Scanner.isVariant(Scanner.roleKey("Anna"), Scanner.roleKey("Ana"), tolerance: 1))
        XCTAssertTrue(Scanner.isVariant(Scanner.roleKey("ANNA"), Scanner.roleKey("Anna"), tolerance: 1))
        XCTAssertFalse(Scanner.isVariant(Scanner.roleKey("Mann 1"), Scanner.roleKey("Mann 2"), tolerance: 1))
        XCTAssertFalse(Scanner.isVariant(Scanner.roleKey("Anna"), Scanner.roleKey("Peter"), tolerance: 2))
    }

    func testRoundTripAndSplit() throws {
        let rows: [[CellValue]] = [
            [.string("Take"), .string("Timecode In"), .string("Timecode Out"), .string("Rolle"), .string("Sprechertext")],
            [.number(1), .string("01:00:10:00"), .string("01:00:30:00"), .string("Anna"),
             .string("Das ist der erste Satz mit einigen Wörtern. Hier kommt der zweite Satz, der etwas länger ist als der erste. Und zum Schluss noch ein dritter Satz.")],
            [.number(2), .string("01:00:29:00"), .string("01:00:35:00"), .string("Ana"), .string("Kurz.")],
            [.number(3), .string("01:00:36:00"), .string(""), .string(""), .string("Ohne Rolle.")],
        ]
        let data = XLSXBuilder.build(sheets: [("Episode 1", rows)])
        let url = URL(fileURLWithPath: "/tmp/test.xlsx")
        let wb = try Workbook(url: url, data: data)
        XCTAssertEqual(wb.sheets.map(\.name), ["Episode 1"])
        let loaded = try wb.loadRows(wb.sheets[0])
        XCTAssertEqual(loaded.count, 4)
        let header = ColumnDetector.guessHeaderRow(loaded)
        XCTAssertEqual(header, 0)
        let m = ColumnDetector.detect(rows: loaded, headerRow: header, fps: 25)
        XCTAssertEqual(m, ColumnMapping(tcIn: 1, tcOut: 2, role: 3, text: 4, takeNumber: 0))

        var sheet = TakeSheet(fileURL: url, sheetName: "Episode 1", sheetPath: wb.sheets[0].path, rows: loaded, headerRowIndex: header, mapping: m)
        var settings = ScanSettings()
        settings.maxWords = 12
        let (props, splitIssues) = Scanner.proposals(for: [sheet], settings: settings)
        XCTAssertTrue(splitIssues.isEmpty)
        XCTAssertEqual(props.count, 1)
        XCTAssertEqual(props[0].parts.count, 3)
        XCTAssertEqual(props[0].parts.map(\.takeNumber), ["1a", "1b", "1c"])
        XCTAssertEqual(props[0].parts.first?.inFrames, 3610 * 25)
        XCTAssertEqual(props[0].parts.last?.outFrames, 3630 * 25)

        let issues = Scanner.integrity([sheet], settings: settings)
        let kinds = Set(issues.map(\.kind))
        XCTAssertTrue(kinds.contains(.missingRole))
        XCTAssertTrue(kinds.contains(.missingTimecode))
        XCTAssertTrue(kinds.contains(.overlap))
        XCTAssertTrue(kinds.contains(.roleSpelling))

        let newRows = Scanner.rows(for: props[0], original: sheet.rows[1], mapping: m, settings: settings)
        sheet.rows.replaceSubrange(1...1, with: newRows)
        sheet.isModified = true
        let out = try XLSXExporter.export(original: data, sheets: [sheet])
        let wb2 = try Workbook(url: url, data: out)
        let rows2 = try wb2.loadRows(wb2.sheets[0])
        XCTAssertEqual(rows2.count, 6)
        XCTAssertEqual(rows2[1].text(1), "01:00:10:00")
        XCTAssertEqual(rows2[3].text(2), "01:00:30:00")
        XCTAssertEqual(rows2[2].text(0), "1b")
        XCTAssertEqual(rows2[4].text(3), "Ana")
    }
}

/// End-to-end run against a real Excel file: TAKELIST_SAMPLE=/path/to.xlsx swift test
final class SampleFileTests: XCTestCase {
    func testSampleFile() throws {
        guard let path = ProcessInfo.processInfo.environment["TAKELIST_SAMPLE"] else { throw XCTSkip("no sample") }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let wb = try Workbook(url: url, data: data)
        print("SHEETS", wb.sheets.map(\.name))
        var settings = ScanSettings()
        settings.maxWords = 20
        var sheets: [TakeSheet] = []
        for info in wb.sheets.prefix(2) {
            let rows = try wb.loadRows(info)
            let h = ColumnDetector.guessHeaderRow(rows)
            let m = ColumnDetector.detect(rows: rows, headerRow: h, fps: 25)
            print("SHEET", info.name, "header", h, m)
            sheets.append(TakeSheet(fileURL: url, sheetName: info.name, sheetPath: info.path, rows: rows, headerRowIndex: h, mapping: m))
        }
        let (props, splitIssues) = Scanner.proposals(for: sheets, settings: settings)
        let tc = Timecode(fps: 25)
        for p in props {
            print("PROPOSAL", p.reason)
            for part in p.parts { print("   ", tc.string(part.inFrames, style: .frames(separator: ":")), tc.string(part.outFrames, style: .frames(separator: ":")), part.takeNumber ?? "-", part.words, part.text) }
        }
        for i in splitIssues + Scanner.integrity(sheets, settings: settings) { print("ISSUE", i.kind, i.message) }
        for s in sheets.indices {
            for p in props where p.sheetID == sheets[s].id {
                let idx = sheets[s].rows.firstIndex { $0.id == p.rowID }!
                sheets[s].rows.replaceSubrange(idx...idx, with: Scanner.rows(for: p, original: sheets[s].rows[idx], mapping: sheets[s].mapping, settings: settings))
                sheets[s].isModified = true
            }
        }
        let out = try XLSXExporter.export(original: data, sheets: sheets)
        let dest = url.deletingLastPathComponent().appendingPathComponent("sample_out.xlsx")
        try out.write(to: dest)
        print("WROTE", dest.path)
    }
}
