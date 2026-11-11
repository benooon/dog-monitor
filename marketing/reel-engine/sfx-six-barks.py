# Sound for the "six barks" reel: snoring, a pigeon, six rounds of barks, the door, the summary ding, the end swell.
import numpy as np, wave, sys
sr = 48000; dur = 15.0; n = int(sr * dur)
rng = np.random.default_rng(29)
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
def bark(pitch=1.0, gain=.55):
    L = .17; t = np.arange(int(L * sr)) / sr
    f = (620 - 900 * t) * pitch                                       # falling "wuf"
    ph = 2 * np.pi * np.cumsum(f) / sr
    body = (np.sin(ph) + .5 * np.sin(2 * ph) + .25 * np.sin(3 * ph))
    rough = lowpass(rng.standard_normal(len(t)), 6) * .6
    e = np.minimum(t / .008, 1) * np.exp(-t / .06)
    return (body + rough) * e * gain
a += lowpass(rng.standard_normal(n), 400) * .05                      # room tone
L = int(.8 * sr); tt = np.arange(L) / sr                              # a snore in the hook
add(lowpass(rng.standard_normal(L), 30) * np.sin(np.pi * tt / .8) * (1 + .6 * np.sin(2 * np.pi * 38 * tt)) * .35, .3)
for t0 in (1.25, 1.5):                                                # the pigeon: coo
    tt = np.arange(int(.22 * sr)) / sr
    add(np.sin(2 * np.pi * (330 + 60 * np.sin(2 * np.pi * 9 * tt)) * tt) * env(.22, .03, .1) * .22, t0)
add(np.sin(2 * np.pi * (500 + 1600 * np.arange(int(.25 * sr)) / sr) * np.arange(int(.25 * sr)) / sr) * env(.25, .005, .08) * .25, 1.56)  # ears up
beats = [2.2, 3.55, 4.9, 6.25, 7.6, 8.95]
for i, b in enumerate(beats):
    add(tone(1900, .03, .006) * .12, b)                               # the cut: a tiny tick
    offs = [.3, .75] if i == 4 else [.45, .8] if i == 5 else [.22, .52, .82]
    for d in offs: add(bark(1.25 if i == 5 else 1.0), b + d)
add(tone(55, .4, .08) * .4, 4.9 + .05);   # the neighbours' door, muffled
add(tone(48, .3, .07) * .3, 4.9 + .14)
for t in np.arange(7.6, 8.9, .09): add(tone(900, .04, .01) * .08, t)  # paws, spinning
L = int(.5 * sr); tt = np.arange(L) / sr                              # door opens at 17:31
add(np.sin(2 * np.pi * (180 + 120 * tt) * tt) * lowpass(rng.standard_normal(L), 8) * env(.5, .05, .25) * .25, 8.95)
add(tone(1318.5, 1.0, .35) * .3 + tone(2637, 1.0, .2) * .05, 10.8)   # summary ding
for k in range(6): add(tone(2200 + k * 120, .04, .01) * .1, 11.15 + k * .1)   # 1..6 count up
for f in (261.6, 329.6, 392.0, 523.3):                                 # end card swell
    add(tone(f, 2.2, 1.2, attack=.4) * .09, 12.75)
a = np.clip(a / max(1, np.abs(a).max()) * .85, -1, 1)
st = np.repeat((a * 32767).astype(np.int16)[:, None], 2, axis=1)
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr); w.writeframes(st.tobytes()); w.close()
