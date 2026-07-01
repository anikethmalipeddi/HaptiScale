# HaptiScale architecture

Implements the hybrid active vibro-acoustic weighing blueprint. The physical model is
a forced, damped coupled oscillator (phone + bowl + food + surface): adding mass
shifts resonance **down** (`f_loaded = f_tare·√(m/(m+Δm))`), lowers Q, broadens the
peak, and shortens ring-down `τ`. We sense those changes as **tare-delta** features.

## Signal chain

```
                 ┌──────────────────────── ExcitationController ───────────────────────┐
                 │  Core Haptics continuous swept sine (sharpness 0→1 ≈ 80→230 Hz,      │
                 │  dwell @ ~0.73 resonance)   +   AVAudioEngine FMCW chirp 18–22 kHz   │
                 └───────────────┬─────────────────────────────────┬───────────────────┘
                                 │ (launched together, same dispatch)
             ┌───────────────────▼──────────┐        ┌─────────────▼──────────────┐
             │ MotionCapture (100 Hz IMU)    │        │ AudioCapture (48 kHz mic,   │
             │ userAccel + gyro + gravity    │        │ .measurement mode, bottom   │
             │ — corroborating, aliases band │        │ mic, lock-free ring buffer) │
             └───────────────────┬──────────┘        └─────────────┬──────────────┘
                                 │                                  │
                                 └────────────┬─────────────────────┘
                                              ▼
                       SyncClock: cross-correlate mic vs emitted reference → lag
                                              ▼
                       FeatureExtractor (coherent averaging over N bursts)
                         • H1 transfer function + coherence (Welch)   ← most informative
                         • matched-filter impulse response → τ, MFCC
                         • structure-borne resonance f / Q / amplitude
                         • IMU RMS, Z:(X,Y) asymmetry, envelope τ, tilt
                         • battery + thermalState covariates
                                              ▼
                       FeatureVector.withTareDelta(baseline)   (loaded − empty)
                                              ▼
                 SetupValidator (soft surface, hand, ambient, off-center, occlusion)
                                              ▼
                 MassEstimator → Core ML (if bundled) else calibration/physics
                                              ▼
                       grams ± CI + quality badge  →  MeasurementCoordinator → SwiftUI
```

## Module map (`HaptiScale/`)

| Folder | Files | Responsibility |
|---|---|---|
| `Core` | `Constants`, `SignalGeneration`, `RingBuffer`, `SyncClock` | Tuning knobs, chirp/reference synthesis, lock-free audio buffer, host-time + cross-correlation alignment |
| `Capture` | `AudioCapture`, `MotionCapture`, `ExcitationController` | Shared AVAudioEngine (chirp + mic tap), 100 Hz Core Motion, synchronized haptic+acoustic burst |
| `DSP` | `FFTProcessor`, `TransferFunction`, `EnvelopeAnalysis`, `MFCC`, `FeatureExtractor` | vDSP FFT, H1 + coherence, Hilbert envelope / τ / Q, MFCCs, feature assembly |
| `Model` | `MeasurementTypes`, `FeatureVector`, `MassEstimator` | Value types, ordered tare-delta feature container, Core ML + calibration/physics estimators |
| `Persistence` | `DeviceProfile`, `BowlRegistry` | Per-model fingerprint + calibration, per-bowl fingerprints (JSON, offline) |
| `Validation` | `SetupValidator` | Green/amber/red gating and rejection |
| `Coordinator` | `MeasurementCoordinator` | State machine: tare → settle → excite×N → extract → validate → estimate |
| `Data` | `DataLogger` | Raw WAV + reference WAV + IMU CSV + metadata JSON for offline training |
| `UI` | `RootView`, `MeasureView`, `BowlsView`, `CalibrateView`, `DataView`, `Components` | SwiftUI |

## Why multimodal

The IMU is capped at **100 Hz**, so it *aliases* the 80–230 Hz Taptic band and cannot
be the primary spectral sensor. The **48 kHz microphone** is the high-resolution
channel for structure-borne vibration; the FMCW chirp's beat-processing tolerates the
unknown speaker→mic latency and iOS resampling. The IMU contributes damping, spatial
(centering) and flatness cues.

## Non-negotiables baked in

- **Tare baseline** before every measurement; every feature is stored as a delta/ratio
  vs. the empty-bowl baseline.
- **Battery level + thermal state** captured per burst and passed to the model.
- **Per-phone-model** profiles (hardware identifier → normalizers/fingerprint).
- **`.measurement` audio mode** to disable AGC; sample rate read back, not assumed.
- **Cross-correlation** sync between the recorded mic signal and the emitted reference.

## Realistic accuracy (from the blueprint)

- Best case (rigid food, stainless/glass, hard surface, calibrated): ~5–12 g MAE.
- Typical (mixed, uncalibrated, cross-session): ~15–30 g MAE.
- Worst (fluffy/leafy, melamine, soft surface): 30–60+ g — should be *rejected*.

## Upgrade path

Log data (Data tab) → `training/train.py` fits a LightGBM quantile regressor and
converts it to Core ML → add `MassModel.mlmodelc` to the app bundle. The estimator
switches to it automatically. A Kirchhoff–Love Padé-activation physics-informed NN is
the further upgrade for extrapolation to unseen masses.
