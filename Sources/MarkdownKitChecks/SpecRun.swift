import Foundation
import MarkdownKit

/// Entry point of the independent CommonMark / GFM conformance suite.
func runSpecConformance() {
    Harness.group("conformance")
    runSpecInline()
    runSpecBlocks()
    runSpecRealWorld()
}
