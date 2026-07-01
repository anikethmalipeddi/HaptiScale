# HaptiScale

A hybrid **active vibro-acoustic food weighing** app for iPhone 12–15. It excites the
phone chassis with a Core Haptics swept sine **and** an inaudible 18–22 kHz speaker
FMCW chirp, records the coupled response on the 100 Hz IMU and the 48 kHz microphone,
extracts **tare-delta** spectral / damping / transfer-function features, and maps them
to grams with a confidence interval.

This is a faithful implementation of the engineering blueprint in
[`ARCHITECTURE.md`](ARCHITECTURE.md). It is a *good-enough* scale for cooking and
portioning — **not** a replacement for a precision jeweler's scale.

## Status

- ✅ Full capture + excitation + DSP + validation + UI pipeline, runnable on device.
- ✅ Ships in **calibration mode**: with no trained model it uses your reference
  weighings (or a physics prior) to estimate grams. Accuracy improves with each
  calibration point.
- 🧪 **Core ML hook** is wired: drop a trained `MassModel.mlmodelc` into the bundle
  and the app switches to it automatically. Train one with `training/train.py` from
  data logged in the **Data** tab.

## Requirements

- **Xcode 16+** (the project uses file-system-synchronized groups / `objectVersion 77`).
- **iOS 16.0+**, and a **physical iPhone** — haptics, the speaker/mic and the IMU do
  not exist in the Simulator. Weighing will not function there.
- A Development Team set on the target for on-device signing.

## Build & run

```bash
open HaptiScale/HaptiScale.xcodeproj
```

1. Select the **HaptiScale** target → Signing & Capabilities → set your Team.
2. Run on a physical iPhone.
3. Grant the microphone prompt.

## Using it (measurement protocol)

1. Lay the phone **flat, screen up, on a hard level surface** (granite/hardwood), away
   from running appliances.
2. **Bowls** tab → register your empty bowl (records its vibration fingerprint).
3. On **Weigh**: place the empty bowl centered on the phone → **Tare**.
4. Add food, hands off, surface still → **Weigh**.
5. Read the estimate + `± CI` + green/amber/red quality badge. **A red badge shows no
   number** — fix the flagged setup issue and re-weigh.

## Improving accuracy

- **Calibrate** tab: weigh a known mass on a real scale, tap Weigh, enter the true
  grams. Two+ points switch the estimator to a fitted curve.
- **Data** tab: log labeled measurements, then train a gradient-boosted model offline
  (`training/train.py`) and add the resulting Core ML model to the app.

## Honest limitations

The bowl-on-table, phone-only configuration is harder than any published result
(VibroScale/MobiScale placed objects *directly on the phone* and still saw ~12 g).
Expect ~8–20 g on rigid, well-coupled foods in a stainless/glass bowl on a hard
surface, degrading badly for fluffy/leafy foods and soft surfaces — which the setup
validator is designed to reject rather than mis-report. See `ARCHITECTURE.md` §
"Realistic accuracy". **Patent note:** US9322701 reads closely on tare-vs-loaded
resonance mass sensing — get FTO counsel before any commercial use.
