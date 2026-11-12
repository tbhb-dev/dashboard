// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import DashboardKit
import XCTest

final class DashboardAppTests: XCTestCase {
    func testTitleIsDashboard() {
        XCTAssertEqual(DashboardKit.title, "Dashboard")
    }
}
