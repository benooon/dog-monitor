// Renders the landing page share images and touch icon into backend/public/media:
// og-en.jpg, og-he.jpg (1200x630) and touch-icon.png (180x180). Run after hero.js.
// Usage: node og.js ../../backend/public/media
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');
const COPY = {
  en: { h1: "What does Rex do when you're out?", sub: 'Your old iPhone becomes the dog camera.' },
  he: { h1: 'מה רקס עושה כשאתם לא בבית?', sub: 'האייפון הישן הופך למצלמת כלב.' },
};
const PAW = '<svg viewBox="0 0 100 100" width="56" height="56"><rect width="100" height="100" rx="23" fill="#B4541F"/><g fill="#fff"><ellipse cx="50" cy="64" rx="22" ry="18"/><ellipse cx="23" cy="40" rx="9" ry="11"/><ellipse cx="40" cy="23" rx="9" ry="11"/><ellipse cx="60" cy="23" rx="9" ry="11"/><ellipse cx="77" cy="40" rx="9" ry="11"/></g></svg>';
(async () => {
  const outDir = path.resolve(process.argv[2] || '.');
  const poster = 'data:image/jpeg;base64,' + fs.readFileSync(path.join(outDir, 'hero.jpg')).toString('base64');
  const fonts = ['latin-500', 'latin-700', 'hebrew-500', 'hebrew-700'].map(f => {
    const [sub, w] = f.split('-');
    const range = sub === 'hebrew' ? ';unicode-range:U+0590-05FF' : '';
    return `@font-face{font-family:Rubik;font-weight:${w};src:url(data:font/woff2;base64,${fs.readFileSync(`${__dirname}/node_modules/@fontsource/rubik/files/rubik-${sub}-${w}-normal.woff2`).toString('base64')})${range}}`;
  }).join('');
  const b = await chromium.launch({ args: ['--allow-file-access-from-files'] });
  const p = await b.newPage({ viewport: { width: 1200, height: 630 } });
  for (const lang of ['en', 'he']) {
    const c = COPY[lang], rtl = lang === 'he';
    await p.setContent(`<html dir="${rtl ? 'rtl' : 'ltr'}"><style>${fonts}
      body{margin:0;width:1200px;height:630px;background:#F7F3EE;font-family:Rubik;display:flex;align-items:center;gap:56px;padding:0 64px;box-sizing:border-box;color:#1C1814}
      .t{flex:1} .b{display:flex;align-items:center;gap:16px;font-weight:500;font-size:30px;color:#6B625A;margin-bottom:28px}
      h1{font-size:${rtl ? 66 : 64}px;line-height:1.08;margin:0 0 24px;font-weight:700} p{font-size:30px;margin:0;color:#6B625A;font-weight:500}
      img{width:480px;height:480px;border-radius:36px;box-shadow:0 24px 60px rgba(60,40,20,.18)}</style>
      <body><div class="t"><div class="b">${PAW}<span dir="ltr">Dog Monitor</span></div><h1>${c.h1}</h1><p>${c.sub}</p></div><img src="${poster}"></body></html>`);
    await p.evaluate(() => document.fonts.ready);
    await p.screenshot({ path: path.join(outDir, `og-${lang}.jpg`), type: 'jpeg', quality: 85 });
  }
  await p.setViewportSize({ width: 180, height: 180 });
  await p.setContent(`<body style="margin:0">${PAW.replace(/width="56" height="56"/, 'width="180" height="180"').replace('rx="23"', 'rx="0"')}</body>`);
  await p.screenshot({ path: path.join(outDir, 'touch-icon.png') });
  await b.close();
})();
