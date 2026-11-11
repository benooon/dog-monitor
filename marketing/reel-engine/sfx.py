# Small original sound design: room tone, door thud, little hop, notification ding, the "busted" sting.
import numpy as np, wave, sys
sr = 48000; dur = 15.0; n = int(sr * dur)
rng = np.random.default_rng(3)
a = np.zeros(n)
def add(sig, t):
    i = int(t * sr); a[i:i + len(sig)] += sig[:max(0, n - i)]
def env(length, attack=.005, decay=.2):
    t = np.arange(int(length * sr)) / sr
    return np.minimum(t / attack, 1) * np.exp(-t / decay)
def tone(f, length, decay, attack=.004):
    t = np.arange(int(length * sr)) / sr
    return np.sin(2 * np.pi * f * t) * env(length, attack, decay)
# room tone (soft filtered noise)
noise = rng.standard_normal(n); k = np.ones(400) / 400
a += np.convolve(noise, k, mode='same') * .05
# door thud
add(tone(70, .5, .09) * .9, 1.25); add(tone(140, .3, .05) * .3, 1.25)
# paws: tiny taps while trotting
for t in np.arange(3.95, 4.9, .16): add(tone(900, .05, .012) * .12, t)
# hop (rising blip) + soft cushion landing
t = np.arange(int(.35 * sr)) / sr
add(np.sin(2 * np.pi * (300 + 900 * t) * t) * env(.35, .01, .12) * .25, 4.9)
add(tone(110, .4, .1) * .5, 5.5)
# notification ding (two notes, original)
add(tone(1318.5, 1.0, .35) * .32 + tone(2637, 1.0, .2) * .06, 6.95)
add(tone(1760, 1.2, .45) * .3 + tone(3520, 1.2, .2) * .05, 7.1)
# busted: low two-note sting
add(tone(196, .5, .25) * .45, 9.6); add(tone(185, .9, .45) * .45, 9.85)
# slide off: falling whistle
t = np.arange(int(1.0 * sr)) / sr
add(np.sin(2 * np.pi * (900 - 500 * t) * t) * env(1.0, .2, .6) * .12, 10.4)
# end card: warm chord swell
for f in (261.6, 329.6, 392.0, 523.3):
    add(tone(f, 2.4, 1.2, attack=.4) * .09, 12.6)
a = np.clip(a / max(1, np.abs(a).max()) * .85, -1, 1)
st = np.repeat((a * 32767).astype(np.int16)[:, None], 2, axis=1)
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr); w.writeframes(st.tobytes()); w.close()
