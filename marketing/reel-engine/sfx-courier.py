# Sound for the "courier" reel: snoring, the doorbell, four minutes of barking, the mail slot, the parcel, a sigh, the ding, tail thumps.
import numpy as np, wave, sys
sr = 48000; dur = 15.0; n = int(sr * dur)
rng = np.random.default_rng(17)
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
def bark(pitch=1.0):
    L = int(.16 * sr); tt = np.arange(L) / sr
    f = (420 - 900 * tt) * pitch
    voice = np.sign(np.sin(2 * np.pi * np.cumsum(f) / sr)) * .5 + np.sin(2 * np.pi * np.cumsum(f * 2) / sr) * .3
    return lowpass(voice + rng.standard_normal(L) * .4, 6) * np.sin(np.pi * tt / .16) ** .5 * .5
a += lowpass(rng.standard_normal(n), 400) * .05                       # room tone
for t0 in (.3, 1.25):                                                  # two snores
    L = int(.7 * sr); tt = np.arange(L) / sr
    add(lowpass(rng.standard_normal(L), 30) * np.sin(np.pi * tt / .7) * (1 + .6 * np.sin(2 * np.pi * 38 * tt)) * .35, t0)
add(tone(659.3, 1.0, .5) * .35 + tone(1318.5, 1.0, .2) * .05, 2.2)      # ding
add(tone(523.3, 1.4, .6) * .35 + tone(1046.5, 1.4, .25) * .05, 2.55)   # dong
tt = np.arange(int(.25 * sr)) / sr                                     # ears pop
add(np.sin(2 * np.pi * (500 + 1600 * tt) * tt) * env(.25, .005, .08) * .25, 2.25)
for t in np.arange(2.95, 3.6, .11): add(tone(900, .05, .012) * .12, t) # paws on tiles
k = 0
for t in np.arange(3.6, 6.95, .26):                                    # full alarm
    add(bark(1.0 + .08 * np.sin(k * 1.7)), t + .01); k += 1
L = int(.06 * sr); add(rng.standard_normal(L) * env(.06, .001, .015) * .6, 6.9)   # mail slot clack
add(tone(1200, .15, .03) * .2, 6.92)
add(tone(90, .3, .06) * .7 + lowpass(rng.standard_normal(int(.3 * sr)), 8) * env(.3, .002, .04) * .3, 7.25)  # parcel hits the mat
L = int(.45 * sr); add(lowpass(rng.standard_normal(L), 20) * np.sin(np.linspace(0, np.pi, L)) * .25, 7.45)     # skid
for t in (7.75, 7.88, 8.0, 8.12):                                      # sniffs
    L = int(.07 * sr); add(lowpass(rng.standard_normal(L), 3) * np.sin(np.linspace(0, np.pi, L)) * .18, t)
L = int(.8 * sr); add(lowpass(rng.standard_normal(L), 60) * np.sin(np.linspace(0, np.pi, L)) * .5, 8.3)   # the sigh
add(tone(70, .4, .08) * .5, 8.55)                                      # flop
add(tone(1318.5, 1.0, .35) * .32 + tone(2637, 1.0, .2) * .06, 9.5)     # notification ding
add(tone(1760, 1.2, .45) * .3 + tone(3520, 1.2, .2) * .05, 9.65)
for t in np.arange(10.3, 12.6, .5): add(tone(85, .18, .05) * .4, t)    # slow tail thumps
for f in (261.6, 329.6, 392.0, 523.3):                                 # end card swell
    add(tone(f, 2.2, 1.2, attack=.4) * .09, 12.75)
a = np.clip(a / max(1, np.abs(a).max()) * .85, -1, 1)
st = np.repeat((a * 32767).astype(np.int16)[:, None], 2, axis=1)
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr); w.writeframes(st.tobytes()); w.close()
