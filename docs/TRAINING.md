# Training a custom sound model

Dog Monitor detects barking with Apple's built-in sound classifier. If it misses your dog's bark or
fires on the TV, you can train a model on your own labeled clips with Create ML and load it on the
camera phone. Everything stays with you: clips come from your household's bucket to your Mac.

## 1. Collect labels

1. In the app, open **Household** and turn on **Help improve detection** (owner only).
   Clips you mark right or wrong are then kept for 90 days instead of 7.
2. In the timeline, mark events **right** or **wrong** for a week or two. Aim for at least
   30 clips per label, including the mistakes (wrong barks are the most useful ones).

## 2. Export the clips

On the household screen, tap **Copy export key** (it works for one hour), then on your Mac:

```sh
DOGMONITOR_API=https://<your API host> DOGMONITOR_TOKEN=<paste the key> \
  node scripts/export-training-data.mjs ~/DogMonitorTraining
```

You get `~/DogMonitorTraining/<event type>/<correct|wrong>/<event id>.mp4`, a snapshot per clip
when there is one, and `labels.csv`. Run it again later to fetch only new clips.

## 3. Make a sound dataset

Create ML's sound classifier wants one folder per label with audio files. The app understands
these labels: `bark`, `howl`, `whimper`, `growl`; anything else (use `other`) is ignored.

```sh
cd ~/DogMonitorTraining
mkdir -p sounds/{bark,whimper,other}
# Correct barking clips are barks; wrong ones are what fooled the detector.
for f in prolongedBarking/correct/*.mp4; do ffmpeg -loglevel error -i "$f" -vn -ac 1 -ar 16000 "sounds/bark/$(basename "$f" .mp4).wav"; done
for f in whining/correct/*.mp4;          do ffmpeg -loglevel error -i "$f" -vn -ac 1 -ar 16000 "sounds/whimper/$(basename "$f" .mp4).wav"; done
for f in */wrong/*.mp4;                  do ffmpeg -loglevel error -i "$f" -vn -ac 1 -ar 16000 "sounds/other/$(basename "$f" .mp4).wav"; done
```

Clips are 10–20 s and include ~5 s from before the event, so trim long files if the label only fits
part of them (QuickTime → Edit → Trim works). Add a few minutes of normal room sound to `other`.

## 4. Train in Create ML

1. Xcode → Open Developer Tool → **Create ML** → New Document → **Sound Classification**.
2. Training Data: the `sounds` folder. Leave Validation on Automatic.
3. Train, then check the Evaluation tab: you want few `other` clips labeled `bark`.
4. Output → Get → save `DogSounds.mlmodel`.

Keep the model small (the default feature extractor is fine): it runs all day on the camera.

## 5. Load it on the camera

AirDrop `DogSounds.mlmodel` to the camera phone (save to Files). In Dog Monitor's camera screen,
before starting, tap **Sound model** → **Load a trained model…** and pick the file. The app compiles
it on the phone and uses it from the next start. **Use the built-in model** switches back.

The custom model replaces only bark/whine detection; loud-noise detection, motion and Vision keep
working as before. If detection gets worse, switch back and add more `other` examples.
