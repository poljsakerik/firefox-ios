// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

/// Keeps DuckDuckGo the only search engine while `enabled`, the value of `MirlumiBuild.onlyDuckDuckGoEnabled`: no other
/// built-in engine and no custom one, so every search the browser starts goes to DuckDuckGo, where safe search is
/// forced.
public enum OnlyDuckDuckGo {
    /// DuckDuckGo's engine ID among the browser's built-in engines.
    public static let engineID = "ddg"

    /// Whether the browser may offer the engine with `engineID`.
    public static func allows(engineID: String, isCustomEngine: Bool, enabled: Bool) -> Bool {
        guard enabled else { return true }
        return engineID == Self.engineID && !isCustomEngine
    }

    /// Whether a custom engine may be added.
    public static func allowsCustomEngines(enabled: Bool) -> Bool {
        return !enabled
    }
}
