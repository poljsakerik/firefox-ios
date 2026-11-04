/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Generated from packages/safe-search/src/safe-search.js in the mirlumi repository by generate.mjs. Don't edit.

var MirlumiSafeSearch = (function () {
  "use strict";

  // DuckDuckGo applies strict safe search to every search served from safe.duckduckgo.com, whatever the page's own
  // setting says. DuckDuckGo documents the host for networks that enforce safe search through DNS. An app can't change
  // DNS for its web view, so Mirlumi sends page loads there instead.
  //
  // This file runs in three places: Node for the tests, Android's built-in extension and iOS's JavaScriptCore. The last
  // one has no URL class, so addresses are taken apart by hand. Both browsers hand over addresses they have already
  // normalised: lower-case scheme and host, no backslashes, default ports removed.

  const SAFE_HOST = "safe.duckduckgo.com";

  // Subdomains that serve no search pages: the results and suggestions APIs, the image proxy, pixels and Email
  // Protection. Every other duckduckgo.com host goes to the safe host, including search hosts DuckDuckGo adds later.
  // next., beta., news., noai., html. and lite. all serve unfiltered results today.
  const PASS_THROUGH_HOSTS = [
    SAFE_HOST,
    "links.duckduckgo.com",
    "ac.duckduckgo.com",
    "external-content.duckduckgo.com",
    "improving.duckduckgo.com",
    "quack.duckduckgo.com",
    "use-login.duckduckgo.com",
  ];

  // The match patterns that cover every address safeSearchUrl may change, for the Android extension's listener. Gecko
  // compares host names literally, so a host written with a trailing dot needs its own patterns.
  const REQUEST_PATTERNS = [
    "*://duckduckgo.com/*",
    "*://*.duckduckgo.com/*",
    "*://duckduckgo.com./*",
    "*://*.duckduckgo.com./*",
  ];

  const ADDRESS = /^(https?):\/\/([^/?#]*)(.*)$/i;

  // The address to load instead of `address`, or null to load it unchanged. The path, query and fragment stay, so a
  // search, an image search or the HTML version open the same page with strict safe search.
  function safeSearchUrl(address) {
    const match = ADDRESS.exec(String(address));
    if (!match) {
      return null;
    }
    const authority = match[2];
    const hostAndPort = authority.slice(authority.lastIndexOf("@") + 1);
    const host = hostAndPort.replace(/:\d*$/, "").replace(/\.$/, "").toLowerCase();
    if (host !== "duckduckgo.com" && !host.endsWith(".duckduckgo.com")) {
      return null;
    }
    if (PASS_THROUGH_HOSTS.includes(host)) {
      return null;
    }
    const rest = match[3] === "" ? "/" : match[3];
    return `https://${SAFE_HOST}${rest}`;
  }

  return { SAFE_HOST, PASS_THROUGH_HOSTS, REQUEST_PATTERNS, safeSearchUrl };
})();
