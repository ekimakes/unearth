/// The steps taken into something, so Back can retrace them.
public struct BackTrail<Step: Equatable>: Equatable {
    public private(set) var steps: [Step] = []

    public init() {}

    /// Where Back goes.
    public var last: Step? { steps.last }

    public mutating func entered(from step: Step) {
        steps.append(step)
    }

    public mutating func back() -> Step? {
        steps.popLast()
    }

    /// Getting to a step some other way leaves nothing after it to go back through.
    public mutating func arrived(at step: Step) {
        if let index = steps.firstIndex(of: step) { steps.removeSubrange(index...) }
    }
}
