# HaptiScale

HaptiScale is an experimental iPhone app that estimates food weight using the phone's haptics, speaker, microphone, and motion sensors.

It sends a controlled vibration through the phone along with an 18–22 kHz audio chirp, records the response from the IMU and microphone, and compares the loaded measurement against a tare measurement to estimate mass in grams.

The goal is to make something useful for cooking and portioning when you do not have a scale nearby. It is not meant to replace a precision scale.

## Status

The full on-device measurement pipeline is implemented, including:

* Haptic and audio excitation
* IMU and microphone capture
* Signal processing and feature extraction
* Tare-based weight estimation
* Measurement quality checks
* Calibration
* Core ML model support
* On-device UI

By default, the app runs in calibration mode. You can enter known reference weights to improve its estimates over time.

If a trained `MassModel.mlmodelc` is added to the app bundle, HaptiScale will automatically use it instead. Training data can be collected from the **Data** tab and used with `training/train.py`.

## Requirements

* Xcode 16+
* iOS 16.0+
* Physical iPhone 12–15
* Apple Development Team configured in Xcode

HaptiScale will not work in the iOS Simulator because it relies on the physical device's haptics, speaker, microphone, and IMU.

## Build

```bash
open HaptiScale/HaptiScale.xcodeproj
```

Then:

1. Select the **HaptiScale** target.
2. Open **Signing & Capabilities** and select your Development Team.
3. Connect a physical iPhone and run the app.
4. Allow microphone access when prompted.

## Usage

1. Place the iPhone flat and screen-up on a hard, level surface.
2. Open the **Bowls** tab and register the empty bowl you want to use.
3. Open **Weigh**, place the empty bowl in the center of the phone, and tap **Tare**.
4. Add food without moving the bowl or phone.
5. Tap **Weigh**.

The result includes an estimated weight, confidence interval, and measurement quality indicator.

If the signal quality is too poor, the app rejects the measurement instead of showing an unreliable weight.

## Calibration

For better results:

1. Measure a known mass using a real scale.
2. Place it in your HaptiScale setup.
3. Take a measurement in the **Calibrate** tab.
4. Enter the actual weight.

Once multiple calibration points are available, the estimator fits the measured response to your specific phone, bowl, and surface.

## Training a Model

The **Data** tab can be used to collect labeled measurements.

Use:

```bash
python training/train.py
```

to train a model from the collected data. The resulting Core ML model can then be added to the app as `MassModel.mlmodelc`.

## Limitations

HaptiScale is sensitive to the physical setup. Bowl material, bowl placement, surface stiffness, food type, and nearby vibration can all affect the measurement.

Rigid foods in a stainless steel or glass bowl on a hard surface generally produce better signals. Soft surfaces and loose, fluffy, or leafy foods are significantly harder to measure reliably.

Current expected accuracy is roughly 8–20 g under good conditions, although results vary by setup.

More details on the measurement system and accuracy assumptions are available in `ARCHITECTURE.md`.

## Disclaimer

HaptiScale is an experimental project and should not be used where precise or safety-critical measurements are required.

US9322701 covers related resonance-based mass sensing techniques. Commercial use should receive an appropriate freedom-to-operate review.
