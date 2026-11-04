// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

#if canImport(UIKit)
import Combine
import SwiftUI
import UIKit

@MainActor
final class AllowedSitesModel: ObservableObject {
    @Published private(set) var sites: [String]
    @Published var opensAllSites: Bool {
        didSet { allowlist.browsingMode = opensAllSites ? .open : .allowlist }
    }
    let offersOpenMode: Bool
    private let allowlist: Allowlist
    private var subscription: AnyCancellable?

    init(allowlist: Allowlist) {
        self.allowlist = allowlist
        sites = allowlist.parentSites
        opensAllSites = allowlist.browsingMode == .open
        offersOpenMode = allowlist.isOpenModeAvailable
        subscription = NotificationCenter.default.publisher(for: Allowlist.parentSitesDidChange, object: allowlist)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sites = allowlist.parentSites }
    }

    func remove(_ site: String) {
        allowlist.remove(site)
    }
}

struct AllowedSitesView: View {
    @ObservedObject var model: AllowedSitesModel

    var body: some View {
        List {
            if model.offersOpenMode {
                Section(footer: Text(AllowlistL10n.string("OpenAllSitesFooter"))) {
                    Toggle(AllowlistL10n.string("OpenAllSites"), isOn: $model.opensAllSites)
                }
            }
            Section(footer: Text(AllowlistL10n.string("AllowedSitesBody"))) {
                if model.sites.isEmpty {
                    Text(AllowlistL10n.string("AllowedSitesEmpty")).foregroundColor(.secondary)
                }
                ForEach(model.sites, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button(AllowlistL10n.string("Remove")) { model.remove(site) }
                            .accessibilityLabel("\(AllowlistL10n.string("Remove")) \(site)")
                    }
                }
            }
        }
    }
}

extension Allowlist {
    /// The title of the Settings row that lists the sites a parent allowed.
    public static var allowedSitesTitle: String { AllowlistL10n.string("AllowedSitesTitle") }

    /// The screen that lists the sites a parent allowed, each with a way to remove it. Push it from Settings, which is
    /// behind the PIN already.
    public func makeAllowedSitesController() -> UIViewController {
        let controller = UIHostingController(rootView: AllowedSitesView(model: AllowedSitesModel(allowlist: self)))
        controller.title = Self.allowedSitesTitle
        return controller
    }
}
#endif

enum AllowlistL10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Allowlist", bundle: .module, comment: "")
    }
}
