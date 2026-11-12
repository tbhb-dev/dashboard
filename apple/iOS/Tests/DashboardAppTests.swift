// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import DashboardKit
import XCTest

final class DashboardAppTests: XCTestCase {
    func testRunsOnTheSimulator() {
        #if targetEnvironment(simulator)
            XCTAssertEqual(DashboardKit.title, "Dashboard")
        #else
            XCTFail("this test must run on the iOS simulator")
        #endif
    }
}
