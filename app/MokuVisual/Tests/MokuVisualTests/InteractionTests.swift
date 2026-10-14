import Foundation
import Testing
import MokuKit
@testable import MokuVisual

@Test func patRequiresHeadStrokeAndReversal() {
    var r = PatRecognizer()
    r.begin(at: CGPoint(x: 50, y: 80), onHead: true, time: 0)
    r.drag(to: CGPoint(x: 70, y: 80)); r.drag(to: CGPoint(x: 48, y: 81))
    #expect(r.end(time: 0.6) == .pat)
    r.begin(at: CGPoint(x: 50, y: 40), onHead: false, time: 0)
    r.drag(to: CGPoint(x: 70, y: 40)); r.drag(to: CGPoint(x: 48, y: 41))
    #expect(r.end(time: 0.6) == .cancelled)
}
@Test func plainClickAndLongDragNeverPat() {
    var r = PatRecognizer(); r.begin(at: .zero, onHead: true, time: 0)
    r.drag(to: CGPoint(x: 2, y: 1)); #expect(r.end(time: 0.2) == .click)
    r.begin(at: .zero, onHead: true, time: 0); r.drag(to: CGPoint(x: 45, y: 0))
    #expect(r.end(time: 0.3) == .cancelled)
}
@Test func allMoodBlendsAreContinuousAndBounded() {
    for mood in Mood.allCases {
        let a = Expression.mood(.content), b = Expression.mood(mood)
        #expect(a.blended(to: b, amount: 0) == a)
        #expect(a.blended(to: b, amount: 1) == b)
        let middle = a.blended(to: b, amount: 0.5)
        #expect(middle.eye >= min(a.eye, b.eye) && middle.eye <= max(a.eye, b.eye))
    }
}
