/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Generated from packages/page-classifier/src/page-text.js in the mirlumi repository by generate.mjs. Don't edit.

var MirlumiPageText = (function () {
  "use strict";

  // Reads the fields the page classifier scores from a loaded document: title, description, headings and the start of
  // the visible text. Runs inside the page, in Android's content script and iOS's user script. The classifier itself runs
  // outside the page, where the page can't reach it.
  //
  // A page can change without loading: a single-page app moves to another address with script, or fills an empty shell
  // after it loads. pageState and changedEnough tell when the page has changed enough to be hidden and checked again. A
  // different address or title always counts; so does a body whose length or text moved by more than small updates such
  // as a ticking clock or a counter would.

  const MAX_BODY_CHARS = 8000;

  function readPage(doc) {
    const meta = doc.querySelector('meta[name="description" i]') || doc.querySelector('meta[property="og:description" i]');
    const headings = [];
    for (const heading of doc.querySelectorAll("h1, h2, h3")) {
      const text = (heading.textContent || "").replace(/\s+/g, " ").trim();
      if (text) {
        headings.push(text);
        if (headings.length >= 30) {
          break;
        }
      }
    }
    // innerText leaves out hidden elements, scripts and styles, like the text a reader sees.
    const body = doc.body ? String(doc.body.innerText || doc.body.textContent || "") : "";
    return {
      title: (doc.title || "").trim(),
      description: meta ? (meta.getAttribute("content") || "").trim() : "",
      headings,
      body: body.replace(/\s+/g, " ").trim().slice(0, MAX_BODY_CHARS),
    };
  }

  // Text is compared in chunks of this many characters. A change counts once at least CHANGED_CHUNKS chunks differ, or
  // the length moved by MIN_LENGTH_CHANGE.
  const CHUNK_CHARS = 500;
  const CHANGED_CHUNKS = 2;
  const MIN_LENGTH_CHANGE = 200;

  function chunkHash(text, start) {
    let hash = 2166136261;
    const end = Math.min(text.length, start + CHUNK_CHARS);
    for (let i = start; i < end; i++) {
      hash = Math.imul(hash ^ text.charCodeAt(i), 16777619);
    }
    return hash >>> 0;
  }

  // What changedEnough compares: the address, the title, and the body's length and chunk hashes.
  function pageState(address, page) {
    const chunks = [];
    for (let start = 0; start < page.body.length; start += CHUNK_CHARS) {
      chunks.push(chunkHash(page.body, start));
    }
    return { address: String(address), title: page.title, length: page.body.length, chunks };
  }

  // Whether a page went from state `before` to `after` by enough to be checked again. No `before` means it was never
  // checked.
  function changedEnough(before, after) {
    if (!before || before.address !== after.address || before.title !== after.title) {
      return true;
    }
    if (Math.abs(after.length - before.length) >= MIN_LENGTH_CHANGE) {
      return true;
    }
    let changed = Math.abs(after.chunks.length - before.chunks.length);
    for (let i = 0; i < Math.min(before.chunks.length, after.chunks.length); i++) {
      if (before.chunks[i] !== after.chunks[i]) {
        changed++;
      }
    }
    return changed >= CHANGED_CHUNKS;
  }

  // How much text a batch of DOM mutations added, removed or changed, for deciding inside a MutationObserver callback, before
  // anything is painted, whether to hide the page while it's checked again.
  function textAdded(records) {
    let length = 0;
    for (const record of records) {
      if (record.type === "characterData") {
        length += (record.target.data || "").length;
      } else if (record.type === "childList") {
        for (const node of [...record.addedNodes, ...(record.removedNodes || [])]) {
          length += (node.textContent || "").length;
        }
      }
    }
    return length;
  }

  return { MAX_BODY_CHARS, readPage, CHUNK_CHARS, CHANGED_CHUNKS, MIN_LENGTH_CHANGE, pageState, changedEnough, textAdded };
})();
