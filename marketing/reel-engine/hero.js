// Renders the landing page hero (backend/public/media/hero.mp4 + hero.jpg): the sofa scene with no
// text, cropped square, as a silent loop. Usage: node hero.js <out dir>
const { chromium } = require('playwright');
const { spawn, execFileSync } = require('child_process');
const path = require('path');
(async () => {
  const outDir = path.resolve(process.argv[2] || '.');
  const fps = 30, t0 = 2.3, t1 = 12.4, crop = 'crop=1080:1080:0:620,scale=720:720';
  const dur = t1 - t0, mp4 = path.join(outDir, 'hero.mp4');
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-',
    '-vf', `${crop},fade=in:st=0:d=0.4,fade=out:st=${(dur - 0.4).toFixed(2)}:d=0.4`,
    '-c:v', 'libx264', '-crf', '28', '-preset', 'slow', '-tune', 'animation', '-pix_fmt', 'yuv420p', '-an', '-movflags', '+faststart', mp4],
    { stdio: ['pipe', 'inherit', 'inherit'] });
  const b = await chromium.launch({ args: ['--allow-file-access-from-files'] });
  const p = await b.newPage({ viewport: { width: 1080, height: 1920 } });
  await p.goto('file://' + __dirname + '/sofa.html');
  await p.evaluate(() => window.ready);
  await p.evaluate(() => { window.clean = true; });
  for (let i = 0; i < Math.round(dur * fps); i++) {
    const d = await p.evaluate(t => window.frame(t, .92), t0 + i / fps);
    if (!ff.stdin.write(Buffer.from(d.split(',')[1], 'base64'))) await new Promise(r => ff.stdin.once('drain', r));
  }
  ff.stdin.end(); await b.close();
  ff.on('close', code => {
    if (code !== 0) { console.error('ffmpeg failed', code); process.exit(1); }
    // Poster: Rex flopped on the sofa.
    execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-ss', String(8.0 - t0), '-i', mp4, '-frames:v', '1', '-q:v', '4', path.join(outDir, 'hero.jpg')]);
  });
})();
