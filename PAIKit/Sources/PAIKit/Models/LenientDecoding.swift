import Foundation

extension KeyedDecodingContainer {
    /// An integer field read the way a forgiving client reads it: a whole number as is, a
    /// fractional one rounded to the nearest whole (halves away from zero), and anything else
    /// (absent, null, a string, a number beyond `Int`) as nil. Apple's `JSONDecoder` throws on a
    /// fraction for an `Int` and so fails the whole payload; one odd field must not do that.
    public func decodeLenientInt(forKey key: Key) -> Int? {
        if let whole = try? decodeIfPresent(Int.self, forKey: key) { return whole }
        guard let fraction = try? decodeIfPresent(Double.self, forKey: key), fraction.isFinite,
            abs(fraction) < 9e15
        else { return nil }
        return Int(fraction.rounded())
    }
}
