import Foundation
import Testing
@testable import UnearthCore

struct ByteFormattingTests {
    private let us = Locale(identifier: "en_US")

    @Test func formatsLikeFinder() {
        #expect(ByteFormatting.string(0, locale: us) == "Zero kB")
        #expect(ByteFormatting.string(54_185_586_688, locale: us) == "54.19 GB")
        #expect(ByteFormatting.string(1_500_000, locale: us) == "1.5 MB")
    }

    @Test func followsTheUsersLocale() {
        #expect(ByteFormatting.string(1_500_000, locale: Locale(identifier: "de_DE")) == "1,5 MB")
    }
}
