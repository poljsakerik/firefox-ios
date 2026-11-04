// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import MirlumiKit
import UIKit

/// The built-in search engines, used instead of Mozilla's Remote Settings list. None carries a partner code.
enum MirlumiSearchEngines {
    static var allowsCustomEngines: Bool {
        OnlyDuckDuckGo.allowsCustomEngines(enabled: MirlumiBuild.onlyDuckDuckGoEnabled)
    }

    /// The engines out of `engines` that `OnlyDuckDuckGo` allows.
    static func allowed(_ engines: [OpenSearchEngine],
                        onlyDuckDuckGo: Bool = MirlumiBuild.onlyDuckDuckGoEnabled) -> [OpenSearchEngine] {
        engines.filter {
            OnlyDuckDuckGo.allows(engineID: $0.engineID, isCustomEngine: $0.isCustomEngine, enabled: onlyDuckDuckGo)
        }
    }

    struct Definition {
        let id: String
        let name: String
        let color: UIColor
        let searchTemplate: String
        let suggestTemplate: String?
    }

    static func definitions(languageCode: String?) -> [Definition] {
        let wikipediaHost = languageCode?.hasPrefix("sl") == true ? "sl.wikipedia.org" : "en.wikipedia.org"
        return [
            Definition(id: OnlyDuckDuckGo.engineID,
                       name: "DuckDuckGo",
                       color: UIColor(red: 0.87, green: 0.35, blue: 0.20, alpha: 1),
                       searchTemplate: "https://duckduckgo.com/?q={searchTerms}",
                       suggestTemplate: "https://duckduckgo.com/ac/?q={searchTerms}&type=list"),
            Definition(id: OpenSearchEngine.googleEngineID,
                       name: "Google",
                       color: UIColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1),
                       searchTemplate: "https://www.google.com/search?q={searchTerms}",
                       suggestTemplate: "https://www.google.com/complete/search?client=firefox&q={searchTerms}"),
            Definition(id: "bing",
                       name: "Bing",
                       color: UIColor(red: 0.05, green: 0.47, blue: 0.56, alpha: 1),
                       searchTemplate: "https://www.bing.com/search?q={searchTerms}",
                       suggestTemplate: "https://www.bing.com/osjson.aspx?query={searchTerms}"),
            Definition(id: "wikipedia",
                       name: "Wikipedia",
                       color: UIColor(red: 0.25, green: 0.27, blue: 0.30, alpha: 1),
                       searchTemplate: "https://\(wikipediaHost)/wiki/Special:Search?search={searchTerms}",
                       suggestTemplate: "https://\(wikipediaHost)/w/api.php?action=opensearch&search={searchTerms}")
        ]
    }

    static func bundled(languageCode: String? = Locale.preferredLanguages.first) -> [OpenSearchEngine] {
        return definitions(languageCode: languageCode).map {
            OpenSearchEngine(engineID: $0.id,
                             shortName: $0.name,
                             telemetrySuffix: nil,
                             image: icon(for: $0),
                             searchTemplate: $0.searchTemplate,
                             suggestTemplate: $0.suggestTemplate,
                             isCustomEngine: false)
        }
    }

    private static func icon(for definition: Definition) -> UIImage {
        let size = CGSize(width: 60, height: 60)
        return UIGraphicsImageRenderer(size: size).image { _ in
            definition.color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12).fill()
            let letter = NSAttributedString(
                string: String(definition.name.prefix(1)),
                attributes: [.font: UIFont.systemFont(ofSize: 36, weight: .semibold), .foregroundColor: UIColor.white]
            )
            let textSize = letter.size()
            letter.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
        }
    }
}
