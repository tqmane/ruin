const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const script = fs.readFileSync(process.argv[2], 'utf8');
function environment(host = 'themeshop.line.me') {
  class Element {
    constructor() { this.attributes = {}; }
    setAttribute(key, value) { this.attributes[String(key).toLowerCase()] = String(value); }
  }
  class HTMLImageElement extends Element {
    get src() { return this._src; }
    set src(value) { this._src = String(value); }
    get srcset() { return this._srcset; }
    set srcset(value) { this._srcset = String(value); }
  }
  class HTMLSourceElement extends Element {
    get srcset() { return this._srcset; }
    set srcset(value) { this._srcset = String(value); }
  }
  const context = { URL, Element, HTMLImageElement, HTMLSourceElement,
    location: { hostname: host }, document: { baseURI: `https://${host}/v2/` } };
  context.window = context;
  vm.createContext(context);
  vm.runInContext(script, context);
  return context;
}
const prefix = 'https://shop.line-scdn.net/themeshop/v1/products/9d/dd/1e/9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/';
const broken = prefix + 'ANDROID/icon_136x202@2x.png';
const working = prefix + 'ANDROID/icon_136x202.png';
const context = environment();
const image = new context.HTMLImageElement();
image.src = broken;
assert.equal(image.src, working);
image.setAttribute('src', broken);
assert.equal(image.attributes.src, working);
image.srcset = `${working} 1x, ${broken} 2x`;
assert.equal(image.srcset, `${working} 1x, ${working} 2x`);
const source = new context.HTMLSourceElement();
source.srcset = `${broken} 2x`;
assert.equal(source.srcset, `${working} 2x`);
source.setAttribute('srcset', `${broken} 2x`);
assert.equal(source.attributes.srcset, `${working} 2x`);
for (const value of [working, prefix + 'IOS/icon_136x202@2x.png',
  broken.replace('shop.line-scdn.net', 'example.com'), broken + '?signature=keep',
  'data:image/svg+xml,%3Csvg%3E', 'https://shop.line-scdn.net/unrelated/icon@2x.png']) {
  image.src = value;
  assert.equal(image.src, value);
}
const setter = Object.getOwnPropertyDescriptor(context.HTMLImageElement.prototype, 'src').set;
vm.runInContext(script, context);
assert.equal(Object.getOwnPropertyDescriptor(context.HTMLImageElement.prototype, 'src').set, setter);
assert(context.__ruinThemeImagesV1.normalized >= 4);
const other = environment('news.line.me');
const untouched = new other.HTMLImageElement();
untouched.src = broken;
assert.equal(untouched.src, broken);
assert.equal(other.__ruinThemeImagesV1, undefined);
console.log('PASS actual Android retina URL normalization, src/srcset/attributes, idempotence and unrelated-page isolation');
