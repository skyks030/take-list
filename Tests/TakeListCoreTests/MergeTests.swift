import XCTest
@testable import TakeListCore

final class MergeTests: XCTestCase {
    let fps = 25

    func sheet(_ url: URL, _ name: String, _ rows: [[CellValue]], mapping: ColumnMapping, path: String = "xl/worksheets/sheet1.xml") -> TakeSheet {
        TakeSheet(fileURL: url, sheetName: name, sheetPath: path, rows: rows.map { SheetRow(sourceRow: nil, cells: $0.map { Cell($0) }) },
                  headerRowIndex: 0, mapping: mapping)
    }

    func testHours() {
        let tc = Timecode(fps: fps)
        XCTAssertEqual(ListMerger.hourFloor(tc.parse("00:00:00:12")!.frames, fps: fps), 0)
        XCTAssertEqual(ListMerger.hourFloor(tc.parse("10:00:00:13")!.frames, fps: fps), tc.parse("10:00:00:00")!.frames)
        XCTAssertEqual(ListMerger.hourAfter(tc.parse("00:42:10:00")!.frames, fps: fps), tc.parse("01:00:00:00")!.frames)
        XCTAssertEqual(ListMerger.suggestedStart(base: 0, previousEnd: tc.parse("00:42:10:00")!.frames, fps: fps), tc.parse("01:00:00:00")!.frames)
        // An own base hour that is already free is kept.
        XCTAssertEqual(ListMerger.suggestedStart(base: tc.parse("03:00:00:00")!.frames, previousEnd: 100, fps: fps), tc.parse("03:00:00:00")!.frames)
    }

    func testMergeShiftsAndKeepsRelativeTimecodes() throws {
        let tc = Timecode(fps: fps)
        let a = sheet(URL(fileURLWithPath: "/a.xlsx"), "Folge 1", [
            [.string("Take"), .string("TC In"), .string("TC Out"), .string("Rolle"), .string("Text")],
            [.number(1), .string("00:00:00:12"), .string("00:00:02:00"), .string("Anna"), .string("Hallo.")],
            [.number(2), .string("00:41:00:00"), .string("00:42:10:00"), .string("Ben"), .string("Tschüss.")],
        ], mapping: ColumnMapping(tcIn: 1, tcOut: 2, role: 3, text: 4, takeNumber: 0))
        // Different layout: combined timecode, other column order, an extra column.
        let b = sheet(URL(fileURLWithPath: "/b.xlsx"), "Folge 2", [
            [.string("Rolle"), .string("Timecode"), .string("Dialog"), .string("Nr"), .string("Notiz")],
            [.string("Carl"), .string("10:00:00:13 - 10:00:01:00"), .string("Moin."), .number(1), .string("laut")],
            [.empty, .empty, .empty, .empty, .empty],
            [.string("Dora"), .string("10:20:00:00 - 10:20:05:24"), .string("Ja."), .number(2), .empty],
        ], mapping: ColumnMapping(tcIn: 1, tcOut: 1, role: 0, text: 2, takeNumber: 3))

        let spanA = try XCTUnwrap(ListMerger.span(of: a, fps: fps))
        let spanB = try XCTUnwrap(ListMerger.span(of: b, fps: fps))
        XCTAssertEqual(spanA, TimecodeSpan(first: 12, last: tc.parse("00:42:10:00")!.frames))
        XCTAssertEqual(spanB.last, tc.parse("10:20:05:24")!.frames)

        let baseB = ListMerger.hourFloor(spanB.first, fps: fps)
        let startB = ListMerger.suggestedStart(base: baseB, previousEnd: spanA.last, fps: fps)
        XCTAssertEqual(startB, baseB) // 10:00 is already after 00:42
        let startB2 = tc.parse("01:00:00:00")!.frames

        let r = try XCTUnwrap(ListMerger.merge([MergeInput(sheet: a, offset: 0), MergeInput(sheet: b, offset: startB2 - baseB)],
                                               name: "Gesamt", fileURL: URL(fileURLWithPath: "/a – Gesamt.xlsx"), fps: fps))
        let rows = r.sheet.rows
        XCTAssertEqual(r.takes, 4)
        XCTAssertEqual(r.addedColumns, ["Notiz"])
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0].text(5), "Notiz")
        XCTAssertEqual(rows[1].text(1), "00:00:00:12")
        XCTAssertEqual(rows[2].text(2), "00:42:10:00")
        XCTAssertEqual(rows[3].text(1), "01:00:00:13")
        XCTAssertEqual(rows[3].text(2), "01:00:01:00")
        XCTAssertEqual(rows[3].text(3), "Carl")
        XCTAssertEqual(rows[3].text(4), "Moin.")
        XCTAssertEqual(rows[3].text(0), "1")
        XCTAssertEqual(rows[3].text(5), "laut")
        XCTAssertEqual(rows[4].text(1), "01:20:00:00")
        XCTAssertEqual(rows[4].text(2), "01:20:05:24")
        // Distance between takes of list B is unchanged.
        let d0 = tc.parse("10:20:00:00")!.frames - tc.parse("10:00:00:13")!.frames
        XCTAssertEqual(tc.parse(rows[4].text(1))!.frames - tc.parse(rows[3].text(1))!.frames, d0)
    }

    func testMergeExcelTimeValuesAndPackage() throws {
        let tc = Timecode(fps: fps)
        let rowsA: [[CellValue]] = [
            [.string("In"), .string("Out"), .string("Rolle"), .string("Text")],
            [tc.cellValue(tc.parse("00:00:01:00")!.frames, style: .excel), tc.cellValue(tc.parse("00:00:02:00")!.frames, style: .excel), .string("A"), .string("x")],
        ]
        let data = XLSXBuilder.build(sheets: [("Rolle 1", rowsA), ("Rolle 2", rowsA)])
        let url = URL(fileURLWithPath: "/tmp/m.xlsx")
        let wb = try Workbook(url: url, data: data)
        let m = ColumnMapping(tcIn: 0, tcOut: 1, role: 2, text: 3)
        let s1 = TakeSheet(fileURL: url, sheetName: "Rolle 1", sheetPath: wb.sheets[0].path, rows: try wb.loadRows(wb.sheets[0]), headerRowIndex: 0, mapping: m)
        let s2 = TakeSheet(fileURL: url, sheetName: "Rolle 2", sheetPath: wb.sheets[1].path, rows: try wb.loadRows(wb.sheets[1]), headerRowIndex: 0, mapping: m)
        let hour = 3600 * fps
        let mergedURL = URL(fileURLWithPath: "/tmp/m – Gesamt.xlsx")
        let r = try XCTUnwrap(ListMerger.merge([MergeInput(sheet: s1, offset: hour), MergeInput(sheet: s2, offset: 2 * hour)],
                                               name: "Gesamt", fileURL: mergedURL, fps: fps))
        XCTAssertEqual(r.sheet.rows[1].cell(0).value, tc.cellValue(tc.parse("01:00:01:00")!.frames, style: .excel))
        XCTAssertEqual(r.sheet.rows[2].cell(1).value, tc.cellValue(tc.parse("02:00:02:00")!.frames, style: .excel))

        let base = try XLSXExporter.singleSheetPackage(original: data, sheetPath: s1.sheetPath, name: "Gesamt")
        let out = try XLSXExporter.export(original: base, sheets: [r.sheet])
        let wb2 = try Workbook(url: mergedURL, data: out)
        XCTAssertEqual(wb2.sheets.map(\.name), ["Gesamt"])
        let rows = try wb2.loadRows(wb2.sheets[0])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(tc.parse(rows[2].cell(0))?.frames, tc.parse("02:00:01:00")!.frames)
    }
}
