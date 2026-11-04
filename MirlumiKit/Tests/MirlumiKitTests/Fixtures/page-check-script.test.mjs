import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

const swift = readFileSync(new URL('../../../Sources/MirlumiKit/PageCheck/PageCheck.swift', import.meta.url), 'utf8');
const script = swift.split('private static let script = """')[1].split('"""')[0]
  .replace('\\(handlerName)', 'mirlumiPageCheck').replace('\\(Int(timeout * 1000))', '3000');

function fixture(loading = false) {
  let observer;
  let page = { body: 'safe', title: '' };
  let style;
  const timers = new Map();
  const events = {};
  const requests = [];
  let nextTimer = 0;
  const root = { appendChild(node) { node.parentNode = this; } };
  const document = {
    documentElement: root, readyState: loading ? 'loading' : 'complete',
    createElement() {
      style = { parentNode: null, remove() { this.parentNode = null; } };
      return style;
    },
    addEventListener(name, callback) { events[name] = callback; }
  };
  const context = {
    document, location: { href: 'https://example.com/' }, addEventListener() {},
    setTimeout(callback, delay) { timers.set(++nextTimer, { callback, delay }); return nextTimer; },
    clearTimeout(id) { timers.delete(id); },
    MutationObserver: class {
      constructor(callback) { observer = { callback }; }
      observe(root, options) { observer.options = options; }
      disconnect() {}
    },
    MirlumiPageText: {
      readPage() { assert.ok(style.parentNode, 'hide before reading'); return { ...page }; },
      pageState(address, value) { return { address, ...value }; },
      changedEnough(a, b) { return JSON.stringify(a) !== JSON.stringify(b); },
      textAdded() { return 0; }
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
    hidden: () => !!style.parentNode,
    observer: () => observer,
    setPage(value) { page = { ...page, body: value }; },
    mutate(target = root, type = 'attributes') {
      observer.callback([{ type, target, addedNodes: [], removedNodes: [] }]);
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

test('attribute reveal hides immediately and rereads before clearing; own style is ignored', async () => {
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
