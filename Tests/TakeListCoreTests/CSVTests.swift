import XCTest
@testable import TakeListCore

final class CSVTests: XCTestCase {
    func testSemicolonQuotedMultiline() throws {
        let csv = "\u{FEFF}Take;TC In;TC Out;Rolle;Text\r\n1;10:00:01:00;10:00:03:12;Anna;\"Sag \"\"hallo\"\";\nzweite Zeile\"\r\n2;10:00:04:00;10:00:05:00;Ben;Für dich\r\n\r\n"
        let text = CSVReader.decode(Data(csv.utf8))
        XCTAssertEqual(CSVReader.detectDelimiter(text), ";")
        let rows = CSVReader.parse(text, delimiter: ";")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1][4], "Sag \"hallo\";\nzweite Zeile")
        XCTAssertEqual(rows[2][4], "Für dich")

        let data = CSVReader.xlsxPackage(Data(csv.utf8), sheetName: "Folge 1")
        let wb = try Workbook(url: URL(fileURLWithPath: "/tmp/f.csv"), data: data)
        XCTAssertEqual(wb.sheets.map(\.name), ["Folge 1"])
        let loaded = try wb.loadRows(wb.sheets[0])
        let m = ColumnDetector.detect(rows: loaded, headerRow: ColumnDetector.guessHeaderRow(loaded), fps: 25)
        XCTAssertEqual(m.tcIn, 1)
        XCTAssertEqual(m.tcOut, 2)
        XCTAssertEqual(m.role, 3)
        XCTAssertEqual(m.text, 4)
    }

    func testCommaAndLatin1() {
        let latin1 = "Rolle,Text,In\nJürgen,\"Ja, gut\",01:00:00:00\n".data(using: .windowsCP1252)!
        let text = CSVReader.decode(latin1)
        XCTAssertEqual(CSVReader.detectDelimiter(text), ",")
        let rows = CSVReader.parse(text, delimiter: ",")
        XCTAssertEqual(rows[1], ["Jürgen", "Ja, gut", "01:00:00:00"])
    }

    func testTab() {
        let text = "A\tB\tC\n1\t2\t3"
        XCTAssertEqual(CSVReader.detectDelimiter(text), "\t")
        XCTAssertEqual(CSVReader.parse(text, delimiter: "\t").last, ["1", "2", "3"])
    }
}
