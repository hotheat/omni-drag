import Foundation
import CoreGraphics

enum WindowSelection {
    struct Candidate {
        let frame: CGRect
        let subrole: String?
    }

    // Prefer a user-facing window over a same-process auxiliary overlay.
    static func bestIndex(in candidates: [Candidate], bounds: CGRect, position: CGPoint) -> Int? {
        var best: (index: Int, role: Int, distance: CGFloat)?
        for (index, candidate) in candidates.enumerated() {
            let frame = candidate.frame
            guard frame.width > 0, frame.height > 0,
                  frame.insetBy(dx: -12, dy: -12).contains(position) else { continue }
            let role = ["AXStandardWindow", "AXDialog", "AXSystemDialog"].contains(candidate.subrole ?? "") ? 0 : 1
            let distance = abs(frame.minX - bounds.minX) + abs(frame.minY - bounds.minY)
                + abs(frame.width - bounds.width) + abs(frame.height - bounds.height)
            if let current = best, current.role < role || (current.role == role && current.distance <= distance) {
                continue
            }
            best = (index, role, distance)
        }
        return best?.index
    }
}
