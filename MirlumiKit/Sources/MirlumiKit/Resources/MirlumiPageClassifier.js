/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Generated from packages/page-classifier/src/page-classifier.js in the mirlumi repository by generate.mjs. Don't edit.

var MirlumiPageClassifier = (function () {
  "use strict";

  // Scores a page's text against Mirlumi's risk categories, on the device.
  //
  // The model is a static embedding model, distilled from a multilingual sentence transformer by Model2Vec: every token
  // has a fixed vector, a text's vector is the average of its tokens' vectors, and a small classifier turns that vector
  // into a probability per category. There is no neural network to run, so plain JavaScript scores a page in
  // milliseconds. The same file runs in Node for training and tests, in Android's built-in extension and in iOS's
  // JavaScriptCore, which has no TextDecoder, URL or WebAssembly, so none are used.
  //
  // Text goes through the tokenizer the embeddings were trained with: normalised, split into words, and each word cut
  // into the most likely sequence of known pieces (SentencePiece Unigram). No piece spans a word boundary, so words are
  // cut one at a time and the results cached.

  const MAGIC = 0x3143504d; // "MPC1", little-endian.
  const WORD_MARK = "▁";
  const PUNCTUATION = /[!-/:-@[-`{-~]/g;
  const MAX_CACHE = 50000;

  // The text of a page that the classifier reads: title, description, headings and the start of the visible text.
  // Search queries and other short texts go to classifyText directly.
  function pageText(page, maxChars) {
    const parts = [page.title, page.description, (page.headings || []).join(" . "), page.body];
    return parts.filter(Boolean).join(" . ").slice(0, maxChars || 4000);
  }

  // The tokenizer's normaliser: NFKC, punctuation set apart, whitespace collapsed. The original uses a precompiled
  // character map, which is NFKC with a few extra mappings; the difference only shifts rare characters.
  function normalize(text) {
    return String(text)
      .normalize("NFKC")
      .replace(PUNCTUATION, " $& ")
      .replace(/\s+/g, " ")
      .trim();
  }

  function utf8Decode(bytes, start, end) {
    let out = "";
    let i = start;
    while (i < end) {
      const b = bytes[i++];
      let code;
      if (b < 0x80) {
        code = b;
      } else if (b < 0xe0) {
        code = ((b & 0x1f) << 6) | (bytes[i++] & 0x3f);
      } else if (b < 0xf0) {
        code = ((b & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
      } else {
        code = ((b & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
      }
      out += String.fromCodePoint(code);
    }
    return out;
  }

  function section(bytes, header, name, Type) {
    const entry = header.sections[name];
    if (!entry) {
      return null;
    }
    const [offset, length] = entry;
    if (Type === Uint8Array) {
      return bytes.subarray(offset, offset + length);
    }
    return new Type(bytes.buffer, bytes.byteOffset + offset, length / Type.BYTES_PER_ELEMENT);
  }

  // Reads a model file: "MPC1", a little-endian uint32 header length, an ASCII JSON header, then the sections it lists.
  // Section offsets are from the start of the file and aligned to 4 bytes.
  function loadModel(bytes) {
    if (!(bytes instanceof Uint8Array)) {
      bytes = new Uint8Array(bytes);
    }
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (view.getUint32(0, true) !== MAGIC) {
      throw new Error("not a page classifier model");
    }
    const headerLength = view.getUint32(4, true);
    const header = JSON.parse(utf8Decode(bytes, 8, 8 + headerLength));

    const pieceBytes = section(bytes, header, "pieces", Uint8Array);
    const pieces = utf8Decode(pieceBytes, 0, pieceBytes.length).split("\n");
    const scores = section(bytes, header, "scores", Float32Array);
    const ids = new Map();
    for (let i = 0; i < pieces.length; i++) {
      ids.set(pieces[i], i);
    }

    return {
      header,
      labels: header.labels || [],
      dim: header.dim,
      ids,
      scores,
      maxPieceLength: header.maxPieceLength,
      unkScore: header.unkScore,
      embeddings: section(bytes, header, "embeddings", Int8Array),
      scales: section(bytes, header, "scales", Float32Array),
      head: header.head
        ? {
            hidden: header.head.hidden || 0,
            w1: section(bytes, header, "w1", Float32Array),
            b1: section(bytes, header, "b1", Float32Array),
            w2: section(bytes, header, "w2", Float32Array),
            b2: section(bytes, header, "b2", Float32Array),
          }
        : null,
      cache: new Map(),
    };
  }

  // The most likely cut of one word into known pieces (Viterbi over piece log-probabilities). A character no piece
  // covers becomes an unknown token, which carries no vector. Returns piece ids, with -1 for unknown.
  function cutWord(model, word) {
    const n = word.length;
    const best = new Float64Array(n + 1).fill(-Infinity);
    const from = new Int32Array(n + 1).fill(-1);
    const piece = new Int32Array(n + 1).fill(-1);
    best[0] = 0;
    for (let start = 0; start < n; start++) {
      if (best[start] === -Infinity) {
        continue;
      }
      // Never start or end a piece inside a surrogate pair.
      const startCode = word.charCodeAt(start);
      if (startCode >= 0xdc00 && startCode <= 0xdfff) {
        continue;
      }
      let matchedSingle = false;
      const maxEnd = Math.min(n, start + model.maxPieceLength);
      for (let end = start + 1; end <= maxEnd; end++) {
        const endCode = word.charCodeAt(end);
        if (end < n && endCode >= 0xdc00 && endCode <= 0xdfff) {
          continue;
        }
        const id = model.ids.get(word.slice(start, end));
        if (id === undefined) {
          continue;
        }
        const score = best[start] + model.scores[id];
        if (score > best[end]) {
          best[end] = score;
          from[end] = start;
          piece[end] = id;
        }
        if (!matchedSingle) {
          const first = word.codePointAt(start);
          matchedSingle = end - start === (first > 0xffff ? 2 : 1);
        }
      }
      if (!matchedSingle) {
        const end = start + (word.codePointAt(start) > 0xffff ? 2 : 1);
        const score = best[start] + model.unkScore;
        if (score > best[end]) {
          best[end] = score;
          from[end] = start;
          piece[end] = -1;
        }
      }
    }
    const out = [];
    for (let end = n; end > 0; end = from[end]) {
      out.push(piece[end]);
    }
    return out.reverse();
  }

  // The piece ids of a text, unknown pieces left out.
  function tokenize(model, text) {
    const normalized = normalize(text);
    if (!normalized) {
      return [];
    }
    const words = (WORD_MARK + normalized.replace(/ /g, WORD_MARK)).split(/(?=▁)/);
    const out = [];
    for (const word of words) {
      let cut = model.cache.get(word);
      if (cut === undefined) {
        cut = cutWord(model, word);
        if (model.cache.size >= MAX_CACHE) {
          model.cache.clear();
        }
        model.cache.set(word, cut);
      }
      for (const id of cut) {
        if (id >= 0) {
          out.push(id);
        }
      }
    }
    return out;
  }

  // The text's vector: the average of its pieces' vectors, scaled to length 1. All zeros if no piece is known.
  function embed(model, text) {
    const dim = model.dim;
    const vector = new Float32Array(dim);
    const ids = tokenize(model, text);
    for (const id of ids) {
      const scale = model.scales[id];
      const row = id * dim;
      for (let j = 0; j < dim; j++) {
        vector[j] += model.embeddings[row + j] * scale;
      }
    }
    let norm = 0;
    for (let j = 0; j < dim; j++) {
      norm += vector[j] * vector[j];
    }
    norm = Math.sqrt(norm);
    if (norm > 0) {
      for (let j = 0; j < dim; j++) {
        vector[j] /= norm;
      }
    }
    return vector;
  }

  // Probabilities per label from a vector. The head is one hidden layer with ReLU, or a linear layer if `hidden` is 0.
  function scoreVector(model, vector) {
    const { hidden, w1, b1, w2, b2 } = model.head;
    const labels = model.labels.length;
    let input = vector;
    let width = model.dim;
    if (hidden) {
      const h = new Float32Array(hidden);
      for (let i = 0; i < hidden; i++) {
        let sum = b1[i];
        const row = i * width;
        for (let j = 0; j < width; j++) {
          sum += w1[row + j] * input[j];
        }
        h[i] = sum > 0 ? sum : 0;
      }
      input = h;
      width = hidden;
    }
    const logits = new Float64Array(labels);
    let max = -Infinity;
    for (let i = 0; i < labels; i++) {
      let sum = b2[i];
      const row = i * width;
      for (let j = 0; j < width; j++) {
        sum += w2[row + j] * input[j];
      }
      logits[i] = sum;
      max = Math.max(max, sum);
    }
    let total = 0;
    for (let i = 0; i < labels; i++) {
      logits[i] = Math.exp(logits[i] - max);
      total += logits[i];
    }
    const scores = {};
    for (let i = 0; i < labels; i++) {
      scores[model.labels[i]] = logits[i] / total;
    }
    return scores;
  }

  function result(model, scores) {
    let top = model.labels[0];
    for (const label of model.labels) {
      if (scores[label] > scores[top]) {
        top = label;
      }
    }
    return { label: top, scores };
  }

  // Scores any text, such as a search query.
  function classifyText(model, text) {
    return result(model, scoreVector(model, embed(model, text)));
  }

  // Scores a page from the fields pageText reads.
  function classifyPage(model, page) {
    return classifyText(model, pageText(page, model.header.maxChars));
  }

  // The risk label a text is flagged for, or null: the most likely label among those whose probability reaches the
  // model's threshold for it. Searches have thresholds of their own, stricter about blocking. A threshold of 1 switches
  // a label off.
  function flaggedLabel(model, scores, isSearch) {
    const thresholds = (isSearch && model.header.searchThresholds) || model.header.thresholds || {};
    let flagged = null;
    for (const label of model.labels) {
      const threshold = thresholds[label];
      if (label === "safe" || threshold === undefined || threshold >= 1 || scores[label] < threshold) {
        continue;
      }
      if (flagged === null || scores[label] > scores[flagged]) {
        flagged = label;
      }
    }
    return flagged;
  }

  // Scores a page and returns { flagged, label, scores }, where flagged is the risk label to block it for, or null.
  function checkPage(model, page) {
    const { label, scores } = classifyPage(model, page);
    return { flagged: flaggedLabel(model, scores), label, scores };
  }

  // The same for a search query, with the search thresholds.
  function checkSearch(model, query) {
    const { label, scores } = classifyText(model, query);
    return { flagged: flaggedLabel(model, scores, true), label, scores };
  }

  const SEARCH_ADDRESS = /^https?:\/\/([^/?#]*)([^?#]*)\?([^#]*)/i;

  function decodeQueryPart(part) {
    try {
      return decodeURIComponent(part.replace(/\+/g, " "));
    } catch (e) {
      return part.replace(/\+/g, " ");
    }
  }

  // The search in a DuckDuckGo results address, the only engine Mirlumi offers, or null for any other address. Covers
  // duckduckgo.com and its subdomains, including the safe, html and lite hosts.
  function searchQuery(address) {
    const match = SEARCH_ADDRESS.exec(String(address));
    if (!match) {
      return null;
    }
    const host = match[1].slice(match[1].lastIndexOf("@") + 1).replace(/:\d*$/, "").replace(/\.$/, "").toLowerCase();
    if (host !== "duckduckgo.com" && !host.endsWith(".duckduckgo.com")) {
      return null;
    }
    for (const pair of match[3].split("&")) {
      const equals = pair.indexOf("=");
      if (equals > 0 && pair.slice(0, equals) === "q") {
        const query = decodeQueryPart(pair.slice(equals + 1)).trim();
        return query || null;
      }
    }
    return null;
  }

  return { pageText, normalize, loadModel, tokenize, embed, scoreVector, classifyText, classifyPage, flaggedLabel, checkPage, checkSearch, searchQuery };
})();
