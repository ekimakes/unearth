import Foundation

/// Words that should find each other, mostly for objects and scenes Vision names ("puppy" finds "dog"),
/// plus plurals ("receipts" finds "receipt").
public enum Synonyms {
    private static let groups: [[String]] = [
        ["dog", "puppy", "canine", "hound"], ["cat", "kitten", "kitty", "feline"], ["horse", "pony"],
        ["bird", "parrot", "pigeon"], ["fish", "aquarium"], ["car", "automobile", "vehicle"], ["bicycle", "bike"],
        ["motorcycle", "motorbike"], ["airplane", "plane", "aircraft", "jet"], ["boat", "ship", "sailboat"],
        ["beach", "shore", "seaside", "coast"], ["sea", "ocean"], ["mountain", "hill", "peak"], ["forest", "woods"],
        ["flower", "blossom", "bloom"], ["sunset", "sunrise", "dusk", "dawn"], ["snow", "snowy", "winter"],
        ["food", "meal", "dish"], ["drink", "beverage"], ["coffee", "espresso", "latte"], ["cake", "dessert"],
        ["baby", "infant", "toddler"], ["child", "kid"], ["people", "person", "crowd"], ["selfie", "portrait"],
        ["receipt", "invoice", "bill"], ["document", "paper"], ["phone", "smartphone", "iphone"],
        ["computer", "laptop", "macbook"], ["house", "home", "building"], ["city", "street", "downtown"],
        ["party", "celebration", "birthday"], ["wedding", "bride", "groom"], ["christmas", "xmas"],
        ["television", "tv"], ["sofa", "couch"], ["glasses", "eyeglasses", "spectacles"],
    ]
    private static let groupOfWord: [String: Int] = {
        var index: [String: Int] = [:]
        for (number, group) in groups.enumerated() {
            for word in group { index[word] = number }
        }
        return index
    }()

    /// The word and its singular ("receipts" → receipts, receipt). These match anywhere.
    public static func forms(of word: String) -> [String] {
        let word = word.lowercased()
        return [word] + (singular(word).map { [$0] } ?? [])
    }

    /// Words for the same thing ("puppy" → dog, canine, hound), never one of the word's own forms.
    /// These only widen what Vision saw in images.
    public static func related(to word: String) -> [String] {
        let forms = forms(of: word)
        var seen = Set(forms)
        return forms.compactMap { groupOfWord[$0] }.flatMap { groups[$0] }.filter { seen.insert($0).inserted }
    }

    /// Everything that should match `word` besides `word` itself.
    public static func expand(_ word: String) -> [String] {
        Array(forms(of: word).dropFirst()) + related(to: word)
    }

    private static func singular(_ word: String) -> String? {
        guard word.count > 3 else { return nil }
        if word.hasSuffix("ies") { return word.dropLast(3) + "y" }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return nil
    }
}
