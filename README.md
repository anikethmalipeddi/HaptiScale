# HaptiScale

An experimental iPhone app that explores whether haptics, audio, and motion sensors can estimate the weight of food in a bowl.

The phone excites the setup, records its response, and compares it with an empty-bowl tare. The app includes signal processing, calibration, measurement quality checks, and an optional Core ML estimator.

This is a prototype, not a validated replacement for a kitchen scale. Accuracy depends on the phone, bowl, surface, and calibration; the repository does not establish a general accuracy guarantee.

## Build

Use Xcode 16 or newer and a physical iPhone running iOS 16 or newer. The simulator cannot reproduce the required sensor measurements.

```sh
open HaptiScale.xcodeproj
```

Select the HaptiScale target, set your Development Team under Signing & Capabilities, and run on the connected phone. Allow microphone access when prompted.

## Try it

1. Place the phone flat on a hard, level surface.
2. Register an empty bowl in the Bowls tab.
3. Place it on the phone and take a tare measurement.
4. Add a known weight and measure again without moving the setup.
5. Use the Calibrate tab to record the reference weight.

The default estimator uses calibration. A compiled `MassModel.mlmodelc` in the app bundle enables the optional trained estimator.

## Training

Collect labeled measurements through the Data tab and copy the phone's `Documents/HaptiScaleData` folder to your computer. The training script needs a data-directory argument:

```sh
python -m pip install 'lightgbm==4.*' scikit-learn pandas numpy 'coremltools==7.*'
python training/train.py /path/to/HaptiScaleData --out MassModel.mlmodel
```

Inspect the validation results before adding a compiled model to the app. See [ARCHITECTURE.md](ARCHITECTURE.md) for the signal chain, assumptions, and limitations.
