/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

const swift = readFileSync(new URL('../../../Sources/MirlumiKit/PageCheck/PageCheck.swift', import.meta.url), 'utf8');
const script = swift.split('private static let script = """')[1].split('"""')[0]
  .replace('\\(handlerName)', 'mirlumiPageCheck').replace('\\(Int(timeout * 1000))', '3000');

function fixture(loading = false) {
  let observer;
  const observers = [];
  let page = { body: 'safe', title: '' };
  let style;
  const timers = new Map();
  const events = {};
  const requests = [];
  let nextTimer = 0;
  let reads = 0;
  const inline = new Map();
  const root = {
    appendChild(node) { node.parentNode = this; },
    style: {
      getPropertyValue(name) { return inline.get(name) || ''; },
      removeProperty(name) { inline.delete(name); },
      setProperty(name, value) { inline.set(name, value); }
    }
  };
  const document = {
    documentElement: root, readyState: loading ? 'loading' : 'complete',
    createElement() {
      style = { parentNode: null, textContent: '', disabled: false, remove() { this.parentNode = null; } };
      return style;
    },
    addEventListener(name, callback) { events[name] = callback; }
  };
  const context = {
    document, location: { href: 'https://example.com/' }, addEventListener() {},
    setTimeout(callback, delay) { timers.set(++nextTimer, { callback, delay }); return nextTimer; },
    clearTimeout(id) { timers.delete(id); },
    MutationObserver: class {
      constructor(callback) { this.callback = callback; this.targets = []; observer = this; observers.push(this); }
      observe(target, options) { this.targets.push(target); this.options = options; }
      disconnect() { this.disconnected = true; }
    },
    MirlumiPageText: {
      readPage() { reads += 1; return { ...page }; },
      pageState(address, value) { return { address, ...value }; },
      changedEnough(a, b) { return JSON.stringify(a) !== JSON.stringify(b); },
      textAdded() { return 0; },
      attributeText(records) {
        return [...new Set(records.map(r => r.target))].reduce((n, t) => n + (t.textContent || '').length, 0);
      }
    },
    window: { webkit: { messageHandlers: { mirlumiPageCheck: {
      postMessage(message) {
        if (message.type === 'start') return Promise.resolve({ check: true, document: 1 });
        return new Promise(resolve => requests.push({ message, resolve }));
      }
    } } } }
  };
  vm.runInNewContext(script, context);
  return {
    requests, events, timers,
    reads: () => reads,
    hidden: () => !!style.parentNode,
    observer: () => observer,
    guard: () => observers[0],
    style: () => style,
    root,
    inline,
    setPage(value) { page = { ...page, body: value }; },
    mutate(target = root, type = 'attributes') {
      observer.callback([{ type, target, addedNodes: [], removedNodes: [] }]);
    },
    // The page touches the gate; WebKit then tells the guard.
    tamper(change) {
      change(style, root);
      observers[0].callback([{ type: 'childList', target: root, addedNodes: [], removedNodes: [style] }]);
    },
    ownMutation() { this.mutate(style); },
    fire(delay) {
      for (const [id, timer] of timers) {
        if (timer.delay === delay) { timers.delete(id); timer.callback(); return; }
      }
      assert.fail(`missing timer ${delay}`);
    }
  };
}
const flush = async () => { await Promise.resolve(); await Promise.resolve(); };
const clear = async (f, index) => {
  const request = f.requests[index];
  request.resolve({ verdict: 'clear', revision: request.message.revision });
  await flush();
};

test('an attribute change that reveals text hides at once and is checked; own style is ignored', async () => {
  const f = fixture();
  await flush();
  await clear(f, 0);
  assert.equal(f.hidden(), false);
  assert.equal(f.observer().options.attributes, true);
  f.ownMutation();
  assert.equal(f.hidden(), false);
  assert.equal(f.timers.size, 0);
  f.setPage('risky '.repeat(200));
  f.mutate();
  assert.equal(f.hidden(), true);
  f.fire(300);
  assert.equal(f.requests.length, 2);
  assert.match(f.requests[1].message.page.body, /risky/);
  await clear(f, 1);
  assert.equal(f.hidden(), false);
});

test('pending clear validates DOM even before observer delivery', async () => {
  const f = fixture();
  await flush();
  f.setPage('new risky content');
  await clear(f, 0);
  assert.equal(f.hidden(), true);
  assert.equal(f.requests.length, 2);
  await clear(f, 1);
  assert.equal(f.hidden(), false);
});

for (const deadlineFirst of [true, false]) {
  test(`parsing startup races safely: deadline first = ${deadlineFirst}`, async () => {
    const f = fixture(true);
    await flush();
    assert.equal(f.requests.length, 0);
    if (deadlineFirst) f.fire(3000);
    f.events.DOMContentLoaded();
    assert.equal(f.requests.length, 1);
    assert.equal(f.timers.size, 0);
    f.events.DOMContentLoaded();
    assert.equal(f.requests.length, 1);
  });
}

test('an animation that only changes attributes keeps the page shown and reads it at most every 100 ms', async () => {
  const f = fixture();
  await flush();
  await clear(f, 0);
  const before = f.reads();
  f.mutate();
  assert.equal(f.hidden(), false);
  assert.equal(f.reads(), before + 1);
  f.mutate();
  f.mutate();
  assert.equal(f.hidden(), false);
  assert.equal(f.reads(), before + 1);
  assert.equal(f.requests.length, 1);
});

const GATE = ':root:root:root:root{opacity:0 !important;pointer-events:none !important}';

test('the gate is guarded from document start: removed, edited, disabled or overridden inline, it comes back', async () => {
  const f = fixture(true);
  await flush();
  // Still parsing: the page check hasn't started watching, but the guard has.
  assert.deepEqual(f.guard().targets, [f.root, f.style()]);
  assert.equal(f.style().textContent, GATE);
  f.tamper((style) => style.remove());
  assert.equal(f.hidden(), true);
  f.tamper((style) => { style.textContent = 'html{}'; });
  assert.equal(f.style().textContent, GATE);
  f.tamper((style) => { style.disabled = true; });
  assert.equal(f.style().disabled, false);
  f.tamper((style, root) => {
    root.style.setProperty('opacity', '1');
    root.style.setProperty('visibility', 'visible');
    root.style.setProperty('display', 'block');
    root.style.setProperty('color', 'red');
  });
  assert.deepEqual([...f.inline.keys()], ['color']);
});

test('once the page is cleared, the guard leaves it alone', async () => {
  const f = fixture();
  await flush();
  await clear(f, 0);
  assert.equal(f.hidden(), false);
  f.tamper((style, root) => root.style.setProperty('opacity', '0.5'));
  assert.equal(f.hidden(), false);
  assert.equal(f.inline.get('opacity'), '0.5');
});

test('the gate stays while a change is being checked', async () => {
  const f = fixture();
  await flush();
  await clear(f, 0);
  f.setPage('risky '.repeat(200));
  f.mutate();
  assert.equal(f.hidden(), true);
  f.tamper((style) => style.remove());
  assert.equal(f.hidden(), true);
});

test('an attribute change on an element with a large passage hides at once, even inside the throttle', async () => {
  const f = fixture();
  await flush();
  await clear(f, 0);
  const small = { textContent: '12:00' };
  f.mutate(small);
  assert.equal(f.hidden(), false);
  const reads = f.reads();
  // Within the throttle window: a small element is only read later, and stays shown.
  f.mutate(small);
  assert.equal(f.hidden(), false);
  assert.equal(f.reads(), reads);
  // A large passage revealed in the same window is hidden before it can be painted, and checked.
  f.setPage('risky '.repeat(200));
  f.mutate({ textContent: 'x'.repeat(250) });
  assert.equal(f.hidden(), true);
  f.fire(300);
  assert.equal(f.requests.length, 2);
  await clear(f, 1);
  assert.equal(f.hidden(), false);
});

test('a class change on the body with unchanged text keeps the page shown', async () => {
  const f = fixture();
  await flush();
  await clear(f, 0);
  f.mutate({ textContent: 'safe '.repeat(100) });
  assert.equal(f.hidden(), false);
  assert.equal(f.requests.length, 1);
});
