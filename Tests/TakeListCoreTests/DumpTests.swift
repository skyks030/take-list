import XCTest
@testable import TakeListCore

/// Structure-only dump of real files (no cell contents): TAKELIST_DUMP="a.xlsx|b.xlsx" swift test --filter DumpTests
final class DumpTests: XCTestCase {
    func testDump() throws {
        guard let list = ProcessInfo.processInfo.environment["TAKELIST_DUMP"] else { throw XCTSkip("no files") }
        for path in list.split(separator: "|").map(String.init) {
            let url = URL(fileURLWithPath: path)
            do {
                let wb = try Workbook(url: url)
                print("FILE", url.lastPathComponent, "sheets:", wb.sheets.count)
                for info in wb.sheets {
                    let (rows, hidden) = try wb.loadSheet(info)
                    let raw = rows.map(\.cells.count).max() ?? 0
                    let used = SheetColumns.used(rows, hidden: hidden)
                    print("  SHEET", info.name, "rows", rows.count, "rawColumns", raw, "usedColumns", used.count, "hidden", hidden)
                }
            } catch { print("FILE", url.lastPathComponent, "ERROR", error) }
        }
    }
}
