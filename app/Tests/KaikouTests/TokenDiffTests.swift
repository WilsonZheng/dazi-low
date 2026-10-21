import XCTest
@testable import Kaikou

final class TokenDiffTests: XCTestCase {
    func testFindsWordReplacements() {
        let pairs = TokenDiff.corrections(inserted: "类似 Tyrex 这种，然后去 Java 建个 ticket。",
                                          edited: "类似 Typeless 这种，然后去 Jira 建个 ticket。")
        XCTAssertEqual(pairs.map { "\($0.0)->\($0.1)" }, ["Tyrex->Typeless", "Java->Jira"])
    }

    func testChineseReplacement() {
        let pairs = TokenDiff.corrections(inserted: "走自身修复流程", edited: "走自审修复流程")
        XCTAssertEqual(pairs.map { "\($0.0)->\($0.1)" }, ["自身修->自审修"])
    }

    func testIgnoresPunctuationAdditionsAndDeletions() {
        XCTAssertTrue(TokenDiff.corrections(inserted: "好的我看一下", edited: "好的，我看一下。").isEmpty)
        XCTAssertTrue(TokenDiff.corrections(inserted: "我看一下", edited: "我先看一下这个 PR").isEmpty)
        XCTAssertTrue(TokenDiff.corrections(inserted: "我先看一下这个", edited: "我看一下").isEmpty)
    }

    func testIgnoresRewrites() {
        let pairs = TokenDiff.corrections(inserted: "这个周末我们去爬山吧大家一起",
                                          edited: "下周二开会讨论一下季度计划安排")
        XCTAssertTrue(pairs.isEmpty, "\(pairs)")
    }

    func testCaseFix() {
        XCTAssertEqual(TokenDiff.corrections(inserted: "push 到 github", edited: "push 到 GitHub").map { $0.1 }, ["GitHub"])
    }
}
