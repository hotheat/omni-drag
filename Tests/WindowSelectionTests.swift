import Foundation
import CoreGraphics

@main enum WindowSelectionTests {
    static func main() {
        typealias Candidate = WindowSelection.Candidate
        let main = CGRect(x: 191, y: 43, width: 1231, height: 868)
        let point = CGPoint(x: 700, y: 300)
        let overlay = Candidate(frame: main, subrole: "AXUnknown")
        let standard = Candidate(frame: main, subrole: "AXStandardWindow")
        func select(_ candidates: [Candidate], _ bounds: CGRect = main) -> Int? {
            WindowSelection.bestIndex(in: candidates, bounds: bounds, position: point)
        }
        precondition(select([overlay, standard]) == 1, "A same-frame overlay must not hide the main window")
        precondition(select([standard, overlay]) == 0, "AX enumeration order must not change the target")
        let displaced = CGRect(x: 418, y: -186, width: 1231, height: 868)
        precondition(select([Candidate(frame: displaced, subrole: "AXUnknown"), standard], displaced) == 1,
                     "An already displaced overlay must not win by exact bounds")
        precondition(select([overlay]) == 0, "Standalone unknown windows must remain supported")
        let elsewhere = Candidate(frame: CGRect(x: 1600, y: 50, width: 200, height: 200), subrole: "AXStandardWindow")
        precondition(select([overlay, elsewhere]) == 0, "A window outside the pointer must not steal the move")
        let dialog = Candidate(frame: CGRect(x: 650, y: 250, width: 300, height: 200), subrole: "AXDialog")
        precondition(select([standard, dialog], dialog.frame) == 1, "A front dialog must beat its parent by geometry")
        precondition(select([elsewhere]) == nil)
        precondition(select([]) == nil)
        precondition(select([Candidate(frame: .zero, subrole: "AXStandardWindow")]) == nil)
        print("WindowSelection: 9 regression checks passed")
    }
}
