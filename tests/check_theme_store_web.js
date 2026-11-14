// Execute the production bridge against a small DOM seam; no network or jsdom.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../src/themes/ThemeStoreWeb.x'), 'utf8');
const strings = source.slice(source.indexOf('static NSString * const source ='),
  source.indexOf('NSString *downloadLabel =')).match(/@?"(?:\\.|[^"\\])*"/g);
const script = strings.map(s => JSON.parse(s.replace(/^@/, ''))).join('')
  .replaceAll('__RUIN_HANDLER__', 'ruinThemeStoreWebDownloadV1')
  .replaceAll('__RUIN_ENABLED__', 'true').replaceAll('__RUIN_READY__', 'false')
  .replaceAll('__RUIN_DOWNLOAD_LABEL__', JSON.stringify('download-fixture'));
const product = '313c6eb8-8584-4f5f-b849-b2b0c7e1c43d';
const otherProduct = 'dda6a0f7-c7b2-40bb-9f27-8077e0db73ca';

function environment(label, options = {}) {
  class Element {
    constructor(value = '') {
      this.value = value; this.attributes = {}; this.isConnected = true;
      this.id = ''; this.className = ''; this.parentElement = null;
      this.disabled = false; this.hidden = false;
    }
    getAttribute(key) { return this.attributes[key] ?? null; }
    getBoundingClientRect() {
      return this.hidden ? { width: 0, height: 0, bottom: 0, right: 0 } :
        { width: 100, height: 40, bottom: 80, right: 120, top: 40, left: 20 };
    }
    matches(selector) { return selector.startsWith('li,') ? this.card : false; }
    closest() { return this; }
  }
  class HTMLInputElement extends Element {}
  const control = new HTMLInputElement(label);
  control.hidden = !!options.hidden;
  control.disabled = !!options.disabled;
  control.card = !!options.card;
  control.attributes['data-product-id'] = options.controlProduct ?? product;
  if (options.recommendation) control.className = 'recommend';
  const controls = options.duplicate ? [control, new HTMLInputElement(label)] : [control];
  if (options.duplicate) controls[1].attributes['data-product-id'] = product;
  const messages = [], listeners = {};
  const document = {
    documentElement: {}, body: new Element(),
    querySelector: () => null, querySelectorAll: () => controls,
    addEventListener: (name, callback) => { listeners[name] = callback; },
  };
  const context = {
    URL, Element, HTMLInputElement, document,
    location: { href: `https://${options.host ?? 'themeshop.line.me'}/themeshop/product/${product}/ko` },
    innerWidth: 800, innerHeight: 600, getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }),
    setTimeout: callback => callback(), MutationObserver: class { observe() {} },
    addEventListener() {},
  };
  if (!options.noBridge) context.webkit = { messageHandlers: {
    ruinThemeStoreWebDownloadV1: { postMessage: message => messages.push(message) },
  } };
  context.window = context;
  vm.createContext(context);
  vm.runInContext(script, context);
  return { context, control, messages, click() {
    let prevented = false;
    listeners.click?.({ target: control, preventDefault() { prevented = true; },
      stopImmediatePropagation() {}, stopPropagation() {} });
    return prevented;
  } };
}

for (const label of ['購入する', 'Purchase', 'Buy', '구매하기', '购买', '購買']) {
  const env = environment(label);
  assert.equal(env.control.value, 'download-fixture', label);
  assert.equal(env.click(), true, label);
  assert.equal(env.messages.length, 1);
  assert.equal(env.messages[0].productID, product);
  assert.equal(env.messages[0].type, 'downloadTheme');
  const url = new URL(env.messages[0].productURL);
  assert.equal(url.host, 'store.line.me');
  assert.equal(url.pathname, `/themeshop/product/${product}/ja`);
  env.context.__ruinThemeStoreWebV1.setEnabled(false);
  assert.equal(env.control.value, label);
  assert.equal(env.click(), false);
}
for (const options of [{ hidden: true }, { disabled: true }, { recommendation: true },
  { controlProduct: otherProduct }, { card: true, controlProduct: '' }, { duplicate: true },
  { host: 'example.invalid' }, { noBridge: true }]) {
  const env = environment('購買', options);
  assert.equal(env.control.value, '購買', JSON.stringify(options));
  assert.equal(env.click(), false, JSON.stringify(options));
  assert.equal(env.messages.length, 0);
}
assert.equal(environment('购买更多').control.value, '购买更多');
const changed = environment('구매하기');
changed.context.location.href = `https://themeshop.line.me/themeshop/product/${otherProduct}/ko`;
changed.click();
assert.equal(changed.messages.length, 0, 'stale product binding must not download');
console.log('PASS production purchase labels, product/visibility/ownership guards and opt-out restoration');
