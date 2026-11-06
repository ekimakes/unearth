import Testing
@testable import UnearthCore

struct GoingBackTests {
    @Test func aFolderGoesBackToTheOneAboveIt() {
        let downloads = "/Users/me/Downloads"
        #expect(Paths.parent(of: "/Users/me/Downloads/Cars/2024", within: downloads) == "/Users/me/Downloads/Cars")
        #expect(Paths.parent(of: "/Users/me/Downloads/Cars", within: downloads) == downloads)
    }

    @Test func thePlaceItselfHasNowhereToGoBackTo() {
        #expect(Paths.parent(of: "/Users/me/Downloads", within: "/Users/me/Downloads") == nil)
        #expect(Paths.parent(of: "/Users/me/Downloads/", within: "/Users/me/Downloads") == nil)
    }

    @Test func aFolderOutsideThePlaceHasNowhereToGoBackTo() {
        #expect(Paths.parent(of: "/Users/me/Documents/Cars", within: "/Users/me/Downloads") == nil)
    }

    @Test func aFolderAtTheTopOfTheDiskGoesBackToIt() {
        #expect(Paths.parent(of: "/Applications", within: "/") == "/")
    }

    @Test func aNewTrailHasNowhereToGoBackTo() {
        #expect(BackTrail<String>().last == nil)
    }

    @Test func backRetracesTheSteps() {
        var trail = BackTrail<String>()
        trail.entered(from: "years")
        trail.entered(from: "months")
        #expect(trail.last == "months")
        #expect(trail.back() == "months")
        #expect(trail.last == "years")
        #expect(trail.back() == "years")
        #expect(trail.back() == nil)
    }

    @Test func gettingToAStepAnotherWayDropsItAndWhatCameAfter() {
        var trail = BackTrail<String>()
        trail.entered(from: "years")
        trail.entered(from: "months")
        trail.arrived(at: "months")
        #expect(trail.steps == ["years"])
        trail.entered(from: "months")
        trail.arrived(at: "years")
        #expect(trail.steps.isEmpty)
    }

    @Test func gettingSomewhereNewKeepsTheTrail() {
        var trail = BackTrail<String>()
        trail.entered(from: "years")
        trail.arrived(at: "all")
        #expect(trail.steps == ["years"])
    }
}
