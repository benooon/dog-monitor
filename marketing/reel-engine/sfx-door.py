# Sound for the "door" reel: door thud, a sigh, snoring, the day ticking by, the wake-up, paws, ding, tail thumps.
import numpy as np, wave, sys
sr = 48000; dur = 15.0; n = int(sr * dur)
rng = np.random.default_rng(11)
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
a += lowpass(rng.standard_normal(n), 400) * .05                      # room tone
add(tone(70, .5, .09) * .9, 1.25); add(tone(140, .3, .05) * .3, 1.25)  # door thud
L = int(.8 * sr); sw = np.sin(np.linspace(0, np.pi, L))               # sigh
add(lowpass(rng.standard_normal(L), 60) * sw * .5, 1.35)
for t0 in (1.9, 2.75):                                                 # two snores
    L = int(.7 * sr); tt = np.arange(L) / sr
    add(lowpass(rng.standard_normal(L), 30) * np.sin(np.pi * tt / .7) * (1 + .6 * np.sin(2 * np.pi * 38 * tt)) * .35, t0)
t, gap = 2.2, .22                                                      # the day ticking by, faster and faster
while t < 3.9:
    add(tone(2400, .03, .006) * .18, t); t += gap; gap = max(.035, gap * .8)
tt = np.arange(int(.25 * sr)) / sr                                     # wake up: ears pop
add(np.sin(2 * np.pi * (500 + 1600 * tt) * tt) * env(.25, .005, .08) * .3, 3.97)
for t in np.arange(4.7, 5.5, .15): add(tone(900, .05, .012) * .12, t)  # paws
add(tone(1318.5, 1.0, .35) * .32 + tone(2637, 1.0, .2) * .06, 5.85)    # notification ding
add(tone(1760, 1.2, .45) * .3 + tone(3520, 1.2, .2) * .05, 6.0)
for t in np.arange(6.1, 9.4, .35): add(tone(85, .18, .05) * .45, t)    # tail thumping the mat
add(tone(660, .12, .04) * .15, 9.52)                                   # the glance at the clock
for t in np.arange(10.6, 12.6, .35): add(tone(85, .18, .05) * .4, t)   # thump, thump: still waiting
for f in (261.6, 329.6, 392.0, 523.3):                                 # end card swell
    add(tone(f, 2.2, 1.2, attack=.4) * .09, 12.75)
a = np.clip(a / max(1, np.abs(a).max()) * .85, -1, 1)
st = np.repeat((a * 32767).astype(np.int16)[:, None], 2, axis=1)
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr); w.writeframes(st.tobytes()); w.close()
