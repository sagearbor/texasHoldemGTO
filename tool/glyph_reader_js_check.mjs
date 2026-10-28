// node tool/glyph_reader_js_check.mjs <compiled.js> [photo_WxH.rgba]
// Hands the CNN asset, the parity fixture and an optional raw RGBA photo to
// the dart2js-compiled tool/glyph_reader_js_check.dart via globals.
import fs from 'node:fs';
import vm from 'node:vm';

const [js, photo] = process.argv.slice(2);
globalThis.self = globalThis;
globalThis.grCnn = new Uint8Array(fs.readFileSync('assets/data/glyph_cnn.bin'));
globalThis.grFixture = new Uint8Array(fs.readFileSync('test/fixtures/glyph_cnn_vectors.bin'));
globalThis.grPhoto = null;
if (photo) {
  const m = photo.match(/_(\d+)x(\d+)\.rgba$/);
  globalThis.grPhoto = new Uint8Array(fs.readFileSync(photo));
  globalThis.grPhotoW = Number(m[1]);
  globalThis.grPhotoH = Number(m[2]);
}
vm.runInThisContext(fs.readFileSync(js, 'utf8'), { filename: js });
