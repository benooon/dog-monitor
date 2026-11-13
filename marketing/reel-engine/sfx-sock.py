# Sound for the "sock" reel: snoring, the basket rustle, paws on oak, the sock sliding under, paw scrapes, the whine, the ding, the reveal.
import numpy as np, wave, sys
sr = 48000; dur = 15.0; n = int(sr * dur)
rng = np.random.default_rng(23)
a = np.zeros(n)
def add(sig, t):
    i = int(t * sr); a[i:i + len(sig)] += sig[:max(0, n - i)]
def env(length, attack=.005, decay=.2):
    t = np.arange(int(length * sr)) / sr
    return np.minimum(t / attack, 1) * np.exp(-t / decay)
def tone(f, length, decay, attack=.004):
    t = np.arange(int(length * sr)) / sr
    return np.sin(2 * np.pi * f * t) * env(length, attack, decay)
def lowpass(x, k):
    return np.convolve(x, np.ones(k) / k, mode='same')
def noise(length, k, amp):
    L = int(length * sr); return lowpass(rng.standard_normal(L), k) * np.sin(np.linspace(0, np.pi, L)) * amp
def whine(length, f0, f1):
    L = int(length * sr); tt = np.arange(L) / sr
    f = f0 + (f1 - f0) * np.sin(np.pi * tt / length) + 12 * np.sin(2 * np.pi * 6 * tt)   # rises, falls, with a wobble
    ph = 2 * np.pi * np.cumsum(f) / sr
    return (np.sin(ph) + .25 * np.sin(2 * ph)) * np.sin(np.pi * tt / length) ** .7 * .22
a += lowpass(rng.standard_normal(n), 400) * .05                       # room tone
for t0 in (.3, 1.25):                                                  # two snores
    L = int(.7 * sr); tt = np.arange(L) / sr
    add(lowpass(rng.standard_normal(L), 30) * np.sin(np.pi * tt / .7) * (1 + .6 * np.sin(2 * np.pi * 38 * tt)) * .35, t0)
for t in (2.65, 2.85, 3.05, 3.2): add(noise(.18, 4, .22), t)          # nose in the laundry, rustle
add(tone(1500, .08, .02) * .08, 3.12)                                  # got it
for t in np.arange(3.65, 5.0, .14): add(tone(1100, .04, .01) * .1, t); add(noise(.03, 2, .05), t)  # claws on oak
L = int(.5 * sr); add(lowpass(rng.standard_normal(L), 12) * np.sin(np.linspace(0, np.pi, L)) * .28, 5.45)   # shove under
tt = np.arange(int(.3 * sr)) / sr                                      # fwip
add(np.sin(2 * np.pi * (900 - 1800 * tt) * tt) * env(.3, .005, .08) * .18, 5.85)
add(noise(.5, 50, .4), 6.3)                                            # satisfied huff
for t in np.arange(7.05, 8.6, .32): add(noise(.2, 6, .25), t)          # paw scraping under the dresser
add(whine(.9, 820, 1150), 8.35)                                        # the whining
add(tone(1318.5, 1.0, .35) * .32 + tone(2637, 1.0, .2) * .06, 8.7)     # notification ding
add(tone(1760, 1.2, .45) * .3 + tone(3520, 1.2, .2) * .05, 8.85)
add(whine(1.1, 760, 1250), 9.4)
add(whine(.8, 900, 1050), 10.25)
add(tone(2400, .05, .01) * .2, 10.9)                                   # torch click
for i, f in enumerate((523.3, 659.3, 784.0)):                          # little reveal chime
    add(tone(f, .8, .3) * .14, 11.05 + i * .09)
for f in (261.6, 329.6, 392.0, 523.3):                                 # end card swell
    add(tone(f, 2.2, 1.2, attack=.4) * .09, 12.75)
a = np.clip(a / max(1, np.abs(a).max()) * .85, -1, 1)
st = np.repeat((a * 32767).astype(np.int16)[:, None], 2, axis=1)
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr); w.writeframes(st.tobytes()); w.close()
