import Foundation

// Inspect the entitlement blob in THIS executable's code signature. Neither a
// build setting nor embedded.mobileprovision proves which entitlements were signed.
struct SignedPushIdentity {
    let environment: String
    let teamID: String
    let bundleID: String

    static func current() -> SignedPushIdentity? {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let values = entitlements(in: data),
              let environment = values["aps-environment"] as? String,
              ["development", "production"].contains(environment),
              let team = values["com.apple.developer.team-identifier"] as? String,
              let application = values["application-identifier"] as? String,
              let bundle = Bundle.main.bundleIdentifier, application == team + "." + bundle else { return nil }
        return SignedPushIdentity(environment: environment == "development" ? "sandbox" : "production", teamID: team, bundleID: bundle)
    }

    static func entitlements(in data: Data) -> [String: Any]? {
        func word(_ offset: Int, big: Bool = false) -> Int? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            let bytes = Array(data[offset..<offset + 4])
            return big ? bytes.reduce(0) { ($0 << 8) | Int($1) } : bytes.reversed().reduce(0) { ($0 << 8) | Int($1) }
        }
        guard word(0) == 0xfeedfacf, let commands = word(16), commands < 1000 else { return nil }
        var offset = 32
        for _ in 0..<commands {
            guard let command = word(offset), let size = word(offset + 4), size >= 8, offset + size <= data.count else { return nil }
            if command == 0x1d {
                guard let start = word(offset + 8), let length = word(offset + 12), length >= 12,
                      start <= data.count - length, word(start, big: true) == 0xfade0cc0,
                      let count = word(start + 8, big: true), count < 1000, 12 + count * 8 <= length else { return nil }
                for index in 0..<count {
                    guard word(start + 12 + index * 8, big: true) == 5,
                          let relative = word(start + 16 + index * 8, big: true), relative >= 0, relative <= length - 8 else { continue }
                    let blob = start + relative
                    guard word(blob, big: true) == 0xfade7171, let bytes = word(blob + 4, big: true),
                          bytes >= 8, bytes <= length - relative else { return nil }
                    return (try? PropertyListSerialization.propertyList(from: data.subdata(in: blob + 8..<blob + bytes), format: nil)) as? [String: Any]
                }
            }
            offset += size
        }
        // Unsigned/simulator/DER-only signature: fail closed, do not guess.
        return nil
    }
}
