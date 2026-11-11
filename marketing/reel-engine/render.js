// Renders the reel for one language straight into ffmpeg (JPEG frames over a pipe, no frame files).
const { chromium } = require('playwright');
const { spawn } = require('child_process');
const fs = require('fs');
(async () => {
  const lang = process.argv[2], out = process.argv[3], dur = 15, fps = 30;
  const tmp = out.replace(/\.mp4$/, '.part.mp4');
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-',
    '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', tmp], { stdio: ['pipe', 'inherit', 'inherit'] });
  const b = await chromium.launch({ args: ['--allow-file-access-from-files'] });
  const p = await b.newPage({ viewport: { width: 1080, height: 1920 } });
  await p.goto('file://' + __dirname + '/' + (process.env.REEL || 'sofa') + '.html');
  await p.evaluate(() => window.ready);
  await p.evaluate(l => window.setLang(l), lang);
  for (let i = 0; i < dur * fps; i++) {
    const d = await p.evaluate(t => window.frame(t, .92), i / fps);
    if (!ff.stdin.write(Buffer.from(d.split(',')[1], 'base64'))) await new Promise(r => ff.stdin.once('drain', r));
  }
  ff.stdin.end(); await b.close();
  ff.on('close', code => { if (code === 0) fs.renameSync(tmp, out); else { console.error('ffmpeg failed', code); process.exit(1); } });
})();
