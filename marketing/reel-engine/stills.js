const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const b = await chromium.launch({ args: ['--allow-file-access-from-files'] });
  const p = await b.newPage({ viewport: { width: 1080, height: 1920 } });
  await p.goto('file://' + __dirname + '/' + (process.env.REEL || 'sofa') + '.html');
  await p.evaluate(() => window.ready);
  const times = process.argv.slice(3).map(Number);
  await p.evaluate(l => window.setLang(l), process.argv[2]);
  for (const t of times) {
    const d = await p.evaluate(t => window.frame(t, .85), t);
    fs.writeFileSync(`still-${process.argv[2]}-${t}.jpg`, Buffer.from(d.split(',')[1], 'base64'));
  }
  await b.close();
})();
