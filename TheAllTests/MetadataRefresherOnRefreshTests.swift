import XCTest
@testable import TheAll

final class MetadataRefresherOnRefreshTests: XCTestCase {

    func testOnRefreshFiresAfterMetadataMutation() {
        let metadata = WorkspaceMetadata()
        let refresher = MetadataRefresher(
            metadata: metadata,
            workingDirectoryProvider: { NSHomeDirectory() })

        let exp = expectation(description: "onRefresh fires on main")
        refresher.onRefresh = {
            XCTAssertTrue(Thread.isMainThread)
            exp.fulfill()
        }

        refresher.start()
        wait(for: [exp], timeout: 5)
        refresher.stop()
    }
}
