/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Generated from packages/safe-search/src/safe-search.js in the mirlumi repository by generate.mjs. Don't edit.

var MirlumiSafeSearch = (function () {
  "use strict";

  // DuckDuckGo applies strict safe search to every search served from safe.duckduckgo.com, whatever the page's own
  // setting says. DuckDuckGo documents the host for networks that enforce safe search through DNS. An app can't change
  // DNS for its web view, so Mirlumi sends page loads there instead, and takes the bangs out of searches, so a search
  // can't hand itself to another site.
  //
  // This file runs in three places: Node for the tests, Android's built-in extension and iOS's JavaScriptCore. The last
  // one has no URL class, so addresses are taken apart by hand. Both browsers hand over addresses they have already
  // normalised: lower-case scheme and host, no backslashes, default ports removed.

  const SAFE_HOST = "safe.duckduckgo.com";

  // Subdomains that serve no search pages: the results API, the image proxy, pixels and Email Protection. Every other
  // duckduckgo.com host goes to the safe host, including search hosts DuckDuckGo adds later. next., beta., news., noai.,
  // html. and lite. all serve unfiltered results today, and so does the suggestions host, ac., under /html/.
  const PASS_THROUGH_HOSTS = [
    SAFE_HOST,
    "links.duckduckgo.com",
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

  // The characters that make DuckDuckGo leave its results. A bang, "!" or the fullwidth "！" before or after a word,
  // as in "!g cats", "cats g!" or "cats!g", opens another site's search. A lone "!" or a leading "\" opens the first
  // result. Searches lose them, so "!g cats" searches DuckDuckGo for "g cats".
  const BANG_CHARACTERS = /[!\\！]/;
  const ALL_BANG_CHARACTERS = /[!\\！]+/g;

  // The HTML and lite versions, at any path that starts like this. Their search forms post the search, and the body of
  // a post can't be rewritten, so they're replaced by the main page.
  const POST_FORM_PATHS = /^\/(?:html|lite)/i;

  // The address to load instead of `address`, or null to load it unchanged. The path, query and fragment stay, so a
  // search or an image search opens the same page with strict safe search. Bangs are removed from the search.
  function safeSearchUrl(address) {
    const host = searchHost(address);
    if (host === null) {
      return null;
    }
    const rest = ADDRESS.exec(String(address))[3];
    const queryStart = rest.search(/[?#]/);
    const path = queryStart < 0 ? rest : rest.slice(0, queryStart);
    const tail = queryStart < 0 ? "" : rest.slice(queryStart);
    const fragmentStart = tail.indexOf("#");
    const query = fragmentStart < 0 ? tail : tail.slice(0, fragmentStart);
    const fragment = fragmentStart < 0 ? "" : tail.slice(fragmentStart);

    const safePath = path === "" || POST_FORM_PATHS.test(path) ? "/" : path;
    const safeQuery = query === "" ? "" : `?${withoutBangs(query.slice(1))}`;
    if (host === SAFE_HOST && safePath === path && safeQuery === query) {
      return null;
    }
    return `https://${SAFE_HOST}${safePath}${safeQuery}${fragment}`;
  }

  // Whether a page load with this method must be cancelled instead of loaded: anything but GET to a DuckDuckGo search
  // host, the safe host included. That's a posted form, whose search the browser can't rewrite. DuckDuckGo's own search
  // box sends the search in the address, and the only pages with a posted form are the ones safeSearchUrl replaces.
  function refusesLoad(address, method) {
    return searchHost(address) !== null && String(method).toUpperCase() !== "GET";
  }

  // The lower-case host of an address on a DuckDuckGo search host, the safe host included, or null for any other address.
  function searchHost(address) {
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
    if (host !== SAFE_HOST && PASS_THROUGH_HOSTS.includes(host)) {
      return null;
    }
    return host;
  }

  // A query string with the bang characters taken out of every search. DuckDuckGo reads the last "q" and splits
  // parameters on ";" as well as "&", so every "q" is cleaned, whatever separates it.
  function withoutBangs(query) {
    return query
      .split(/([&;])/)
      .map((part, index) => (index % 2 === 1 ? part : searchWithoutBangs(part)))
      .join("");
  }

  function searchWithoutBangs(parameter) {
    const equals = parameter.indexOf("=");
    if (equals < 0) {
      return parameter;
    }
    const rawName = parameter.slice(0, equals);
    const name = decode(rawName);
    if (name === null || name.toLowerCase() !== "q") {
      return parameter;
    }
    const search = decode(parameter.slice(equals + 1));
    if (search === null) {
      // Encoding a browser wouldn't produce. DuckDuckGo could read a bang in it, so the search is dropped.
      return `${rawName}=`;
    }
    if (!BANG_CHARACTERS.test(search)) {
      return parameter;
    }
    const cleaned = search.replace(ALL_BANG_CHARACTERS, " ").replace(/\s+/g, " ").trim();
    return `${rawName}=${encodeURIComponent(cleaned).replace(/%20/g, "+")}`;
  }

  function decode(component) {
    try {
      return decodeURIComponent(component.replace(/\+/g, " "));
    } catch (e) {
      return null;
    }
  }

  return { SAFE_HOST, PASS_THROUGH_HOSTS, REQUEST_PATTERNS, safeSearchUrl, refusesLoad };
})();
