# Conversation Awareness

A cross-platform Flutter app for Android and iOS that automatically reduces or pauses media volume when it detects your voice — bringing the AirPods Conversation Awareness experience to any device or headphones.

---

## Table of Contents

- [Features](#features)
- [How It Works](#how-it-works)
- [Project File Structure](#project-file-structure)
- [Android Setup](#android-setup)
- [iOS Setup](#ios-setup)
- [YAMNet Model Setup](#yamnet-model-setup)
- [Building for Release](#building-for-release)
- [Settings Reference](#settings-reference)
- [Architecture](#architecture)
- [Platform Differences](#platform-differences)
- [Troubleshooting](#troubleshooting)

---

## Features

| Feature | Android | iOS |
|---|---|---|
| Auto volume duck when speaking | ✅ | ✅ |
| Pause audio entirely when speaking | ✅ | ✅ |
| RMS amplitude detection (low battery) | ✅ | ✅ |
| Neural Net detection via YAMNet AI | ✅ | ✅ |
| Live noise meter with threshold slider | ✅ | ✅ |
| NN sensitivity slider | ✅ | ✅ |
| Background operation | ✅ (Foreground Service) | ⚠️ (foreground only) |
| Persistent notification with Stop button | ✅ | — |
| Automatic Bluetooth mic switching | ✅ | ✅ |
| Wired headset mic switching | ✅ | ✅ |
| Manual mic source selection | ✅ | ✅ |
| Configurable silence timeout (0–10 s) | ✅ | ✅ |
| Configurable ducked volume (0–95%) | ✅ | ✅ |
| Instant restore mode | ✅ | ✅ |
| All settings persisted across restarts | ✅ | ✅ |
| Burst noise filter (4-poll confirmation) | ✅ | ✅ |
| 500 ms debounce before countdown UI | ✅ | ✅ |

---

## How It Works

```
Microphone (PCM audio)
        │
        ▼
  Detection mode?
  ┌─────┴──────┐
  │ RMS        │ Neural Net
  │            │
  ▼            ▼
Amplitude   YAMNet model
threshold   (15 600 samples
comparison  = 975 ms window)
  │            │
  └─────┬──────┘
        ▼
  4 consecutive polls above threshold?
        │
       YES → Duck / Pause volume
        │         │
        │    Silence detected
        │         │
        │    500 ms debounce
        │         │
        │    Start countdown
        │         │
        │    Timeout reached
        │         │
        └─────────┘
              ▼
        Restore volume
```

---

## Project File Structure

```
conversation_awareness/
│
├── pubspec.yaml                          # Dependencies and version
├── key.properties                        # Signing credentials (never commit)
│
├── lib/
│   ├── main.dart                         # App entry point, theme
│   ├── home_screen.dart                  # Main UI, state management
│   ├── audio_monitor_service.dart        # Dart ↔ native method channel wrapper
│   ├── settings_repository.dart          # SharedPreferences persistence layer
│   └── permission_helper.dart            # Runtime microphone permission flow
│
├── android/
│   ├── build.gradle.kts                  # Root-level Gradle config (Kotlin DSL)
│   ├── gradle.properties                 # android.newDsl=false, AndroidX flags
│   └── app/
│       ├── build.gradle                  # App-level Gradle config (Groovy)
│       ├── proguard-rules.pro            # R8 keep rules for release builds
│       └── src/main/
│           ├── AndroidManifest.xml       # Permissions, service declaration
│           ├── assets/
│           │   └── yamnet.tflite         # YAMNet TFLite model (must add manually)
│           ├── kotlin/com/device_tools/conversation_awareness/
│           │   ├── MainActivity.kt       # Registers the plugin with Flutter
│           │   ├── ConversationAwarenessPlugin.kt  # Core native plugin
│           │   ├── ConversationForegroundService.kt # Background service + notification
│           │   └── VoiceDetector.kt      # YAMNet MediaPipe wrapper
│           └── res/values/
│               └── styles.xml            # Launch and normal theme
│
└── ios/
    └── Runner/
        ├── AppDelegate.swift             # Registers the plugin with Flutter
        ├── ConversationAwarenessPlugin.swift  # Core iOS native plugin
        ├── Info.plist                    # NSMicrophoneUsageDescription
        └── yamnet.mlmodelc/              # Compiled CoreML model (add via Xcode)
```

> **Key files to never commit to version control:**
> - `key.properties` — contains keystore passwords
> - `*.jks` / `*.keystore` — the keystore file itself
> - Add both to `.gitignore`

---

## Android Setup

### Prerequisites

- Flutter SDK ≥ 3.10
- Android Studio Hedgehog (2023.1) or later
- Android SDK API 36 or higher
- A physical Android device (API 23+) or emulator

### Steps

**1. Clone or copy the project**

**2. Set the correct package name**

If your package name is not `com.device_tools.conversation_awareness`, update it in:
- `android/app/build.gradle` → `applicationId` and `namespace`
- `android/app/src/main/AndroidManifest.xml` → remove `package=` attribute (not needed in AGP 8+)
- All four Kotlin files → `package` declaration at the top of each file

**3. Add the YAMNet model**

See [YAMNet Model Setup](#yamnet-model-setup) below.

**4. Install dependencies**

```bash
flutter pub get
```

**5. Run in debug mode**

```bash
flutter run
```

### Required Permissions

The following are declared in `AndroidManifest.xml` and requested at runtime:

| Permission | Purpose |
|---|---|
| `RECORD_AUDIO` | Microphone access for voice detection |
| `MODIFY_AUDIO_SETTINGS` | Adjusting media stream volume |
| `FOREGROUND_SERVICE` | Running in the background |
| `FOREGROUND_SERVICE_MICROPHONE` | Background mic use on Android 14+ |
| `POST_NOTIFICATIONS` | Persistent background notification |
| `BLUETOOTH` / `BLUETOOTH_CONNECT` | Bluetooth headset mic detection |

---

## iOS Setup

### Prerequisites

- macOS with Xcode 14+
- Flutter SDK ≥ 3.10
- CocoaPods
- iOS 14.0+ device or simulator

### Steps

**1. Open the project correctly**

Always open `ios/Runner.xcworkspace` — never `Runner.xcodeproj`.

**2. Add the Swift plugin files**

Place these two files in `ios/Runner/` and add them to the Runner target
(select file → File Inspector → check Runner under Target Membership):
- `ConversationAwarenessPlugin.swift`
- `AppDelegate.swift` (replace existing)

**3. Add microphone permission**

In `ios/Runner/Info.plist`, add inside the root `<dict>`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Conversation Awareness needs microphone access to detect when you speak and reduce media volume.</string>
```

**4. Set minimum iOS version**

In `ios/Podfile`, ensure the first line reads:

```ruby
platform :ios, '14.0'
```

**5. Add the YAMNet CoreML model**

See [YAMNet Model Setup](#yamnet-model-setup) below.

**6. Install pods and run**

```bash
cd ios && pod install && cd ..
flutter run
```

---

## YAMNet Model Setup

YAMNet is a pre-trained audio classification model from Google that identifies human speech among 521 sound categories. It must be added manually because the model file is too large to include in the repository.

### Android — `.tflite` file

1. Download the YAMNet TFLite model from Kaggle:
   **https://www.kaggle.com/models/google/yamnet/tfLite/classification-tflite/1**
   (Free Kaggle account required)

2. Rename the downloaded file to `yamnet.tflite`

3. Place it at:
   ```
   android/app/src/main/assets/yamnet.tflite
   ```
   Create the `assets/` folder if it doesn't exist.

4. The `build.gradle` already contains `aaptOptions { noCompress "tflite" }` which
   prevents the packager from compressing the model — this is required for MediaPipe
   to memory-map it correctly.

### iOS — `.mlpackage` → `.mlmodelc`

iOS uses CoreML and requires the model to be converted from TensorFlow format first.

**Step 1 — Install Python dependencies**

```bash
pip3 install tensorflow==2.13.0 tensorflow-hub coremltools numpy
```

**Step 2 — Create and run the conversion script**

Create `convert_yamnet.py` on your Desktop:

```python
import tensorflow as tf
import tensorflow_hub as hub
import coremltools as ct
import numpy as np
import os

print("Loading YAMNet from TensorFlow Hub...")
model = hub.load("https://tfhub.dev/google/yamnet/1")

@tf.function(input_signature=[
    tf.TensorSpec(shape=[15600], dtype=tf.float32, name="waveform")
])
def predict(waveform):
    scores, embeddings, spectrogram = model(waveform)
    return {"scores": scores}

concrete_func = predict.get_concrete_function()

print("Converting to CoreML...")
mlmodel = ct.convert(
    concrete_func,
    inputs=[ct.TensorType(name="waveform", shape=(15600,), dtype=np.float32)],
    outputs=[ct.TensorType(name="scores")],
    minimum_deployment_target=ct.target.iOS16,
)

output_path = os.path.expanduser("~/Desktop/yamnet.mlpackage")
mlmodel.save(output_path)
print(f"Saved to {output_path}")
```

Run it:
```bash
python3 ~/Desktop/convert_yamnet.py
```

**Step 3 — Add to Xcode**

1. Open `ios/Runner.xcworkspace` in Xcode
2. Right-click the **Runner** folder in the Project Navigator
3. Select **Add Files to "Runner"**
4. Select `yamnet.mlpackage` from your Desktop
5. Check **Copy items if needed** and **Add to targets: Runner**
6. Click **Add** — Xcode compiles it to `yamnet.mlmodelc` automatically at build time

---

## Building for Release

### Android App Bundle (.aab)

**1. Create a keystore** (one-time, keep this file safe forever):

```powershell
keytool -genkey -v `
  -keystore "C:\Users\YourName\upload-keystore.jks" `
  -storetype JKS -keyalg RSA -keysize 2048 `
  -validity 10000 -alias upload
```

**2. Create `key.properties`** in the project root (alongside `pubspec.yaml`):

```properties
storePassword=YOUR_KEYSTORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=upload
storeFile=C:\\Users\\YourName\\upload-keystore.jks
```

Note: use double backslashes on Windows.

**3. Bump the version** in `pubspec.yaml` before every upload:

```yaml
version: 1.0.1+2   # format: versionName+versionCode
```

The `versionCode` (after `+`) must increase with every Play Store upload.

**4. Build:**

```bash
flutter build appbundle --release
```

Output: `build/app/outputs/bundle/release/app-release.aab`

**5. Upload** the `.aab` to Google Play Console under your chosen release track.

### iOS Archive (.ipa)

1. Open `ios/Runner.xcworkspace` in Xcode
2. Select **Any iOS Device** as the build target
3. Go to **Product → Archive**
4. In the Organizer, click **Distribute App**
5. Follow the App Store Connect upload wizard

---

## Settings Reference

All settings are saved automatically and restored on next launch.

| Setting | Range | Default | Notes |
|---|---|---|---|
| Detection mode | RMS / Neural Net | RMS | NN requires yamnet model file |
| NN Sensitivity | Very Low → Very High | Medium | Only in Neural Net mode |
| Microphone input | Auto / Built-in / Bluetooth | Auto | Auto follows device connections |
| Silence timeout | 0s (Instant) → 10s | 3s | How long silence before volume restores |
| Pause audio | On / Off | Off | Pauses Spotify, YouTube etc. instead of ducking |
| Ducked volume | 0% (Mute) → 95% | 20% | Hidden when Pause audio is on |
| Voice threshold | 0 → 2000 RMS | 500 | RMS mode only; use live meter to calibrate |

### Changing settings while running

| Setting | Live update? |
|---|---|
| NN Sensitivity | ✅ Instant |
| Voice threshold | ✅ Instant |
| Microphone input | ✅ Instant (triggers reroute) |
| Pause audio | ✅ Instant |
| Detection mode | ✅ Instant |
| Silence timeout | ✅ Applied on next silence event |
| Ducked volume | ✅ Applied immediately if voice is active |

---

## Architecture

### Method Channel

All native communication uses a single `MethodChannel`:
```
com.example.conversation_awareness/audio
```

**Flutter → Native (method calls):**

| Method | Parameters | Description |
|---|---|---|
| `startMonitoring` | timeout, volume, threshold, mode, sensitivity, pauseAudio | Start mic + detection |
| `stopMonitoring` | — | Stop everything, restore volume |
| `setThreshold` | voiceThreshold | Live RMS threshold update |
| `setSettings` | silenceTimeoutSeconds, duckedVolumeFraction | Live timeout/volume update |
| `setDetectionMode` | mode ("rms"/"nn") | Switch detection algorithm live |
| `setNNSensitivity` | sensitivity (0.0–1.0) | Live NN threshold update |
| `setMicMode` | mode ("auto"/"builtin"/"bluetooth") | Switch mic source |
| `setPauseAudio` | enabled | Toggle pause vs duck behaviour |
| `getInputDevices` | — | List available input devices |

**Native → Flutter (events):**

| Event | Argument | Description |
|---|---|---|
| `onVoiceDetected` | — | Voice confirmed, volume ducked |
| `onSilenceCountdown` | remaining (int seconds) | Countdown tick |
| `onSilenceRestored` | — | Silence timeout reached, volume restored |
| `onAmplitude` | rms (int, 0–32768) | Live meter reading (~12/sec) |
| `onMicSource` | "builtin"/"bluetooth"/"wired" | Active mic changed |
| `onMicMode` | "auto"/"builtin"/"bluetooth" | User preference changed |
| `onDetectionMode` | "rms"/"nn" | Detection mode changed |
| `onStoppedFromNotification` | — | User tapped Stop in notification |
| `onMicError` | message | Mic routing failure |

### Voice Detection — RMS Mode

1. `AudioRecord` reads PCM at 16 kHz mono
2. RMS amplitude calculated per buffer
3. Must exceed `voiceThreshold` for **4 consecutive polls** (~330 ms) to confirm voice
   — this prevents mic-movement noise bursts from triggering ducking
4. Silence debounced 500 ms before countdown UI appears

### Voice Detection — Neural Net Mode

1. PCM samples written into a 15 600-sample ring buffer (975 ms of audio)
2. Once buffer is full, inference runs on every new buffer:
   - **Android:** MediaPipe `AudioClassifier` with `yamnet.tflite`
   - **iOS:** CoreML `MLModel` with `yamnet.mlmodelc`
3. Scores for AudioSet classes 0–3 (Speech, Male speech, Female speech, Child speech)
   are summed
4. Sum compared against threshold derived from `nnSensitivity`:
   `threshold = 0.80 - sensitivity × (0.80 - 0.10)`
5. YAMNet's 975 ms window provides inherent temporal smoothing —
   no additional poll-count filter needed

### Bluetooth / Wired Mic Routing — Android

- `AudioManager.AudioDeviceCallback` watches for device connect/disconnect
- On Bluetooth connect: `startBluetoothSco()` + `AudioRecord.setPreferredDevice()`
- On wired headset connect: `setPreferredDevice()` + `AudioManager.MODE_IN_COMMUNICATION`
  (forces OS audio policy to prefer headset mic over built-in)
- On disconnect: device unpinned, `MODE_NORMAL` restored, falls back gracefully

### Background Operation — Android

`ConversationForegroundService` is a standard Android Foreground Service:
- Started when monitoring begins, stopped when monitoring ends
- Shows a persistent notification with app name, status text, and a **Stop** button
- The Stop button sends `ACTION_STOP_MONITORING` broadcast → plugin stops monitoring
  → fires `onStoppedFromNotification` → Flutter UI resets to Off state
- `foregroundServiceType="microphone"` declared in manifest (required Android 14+)

### Persistence

`SettingsRepository` wraps `SharedPreferences` (Android) / `NSUserDefaults` (iOS):

| Key | Type | Default |
|---|---|---|
| `silence_timeout_seconds` | Int | 3 |
| `ducked_volume_fraction` | Double | 0.2 |
| `voice_threshold` | Int | 500 |
| `detection_mode` | String | "rms" |
| `mic_mode` | String | "auto" |
| `nn_sensitivity` | Double | 0.5 |
| `pause_audio` | Bool | false |

---

## Platform Differences

| Behaviour | Android | iOS |
|---|---|---|
| **Volume ducking** | Sets exact % via `AudioManager.setStreamVolume()` | Uses `.duckOthers` AVAudioSession option (OS controls level) |
| **Pause audio** | `AudioFocusRequest` `AUDIOFOCUS_GAIN_TRANSIENT` | Deactivates `.mixWithOthers` to interrupt other sessions |
| **Background** | Foreground Service with notification | App must stay in foreground |
| **Wired headset** | `MODE_IN_COMMUNICATION` + `setPreferredDevice()` | `setPreferredInput()` with port type check |
| **YAMNet format** | `.tflite` via MediaPipe Tasks Audio | `.mlmodelc` via CoreML |
| **Ducked volume %** | Applied exactly | Display only — iOS controls actual attenuation |

---

## Troubleshooting

### "yamnet.tflite not found" (Android)
Place `yamnet.tflite` in `android/app/src/main/assets/`. Create the `assets/` folder if it doesn't exist. Clean and rebuild.

### "yamnet.mlmodelc not found" (iOS)
Add `yamnet.mlpackage` to the Xcode project with target membership set to Runner. Xcode compiles it automatically. Clean build folder (⇧⌘K) and rebuild.

### Wired headset mic not switching
- Confirmed fixed in current version via `AudioManager.MODE_IN_COMMUNICATION`
- If still not working on your device, try unplugging and replugging while the app is listening
- Some devices require the headset to be connected before starting monitoring

### Notification Stop button doesn't update the app UI
- Confirmed fixed in current version — `onStoppedFromNotification` event resets both `_state` and `_displayState` to idle
- If the app shows "Listening" after tapping Stop, force-close the app and reopen it

### Volume not restoring after stop
- This can happen if the app crashes while voice is active
- Go to your device's volume controls and manually adjust — the OS doesn't lock the volume

### "Version code X has already been used" (Play Store)
- Increment the number after `+` in `pubspec.yaml` (e.g. `1.0.0+3`)
- Rebuild and re-upload

### Build fails with "Unresolved reference: ConversationForegroundService"
- All four Kotlin files must have the same `package` declaration at the top
- Make sure it matches the `applicationId` in `build.gradle`

### "Cannot find target android-37"
- Pin `permission_handler: 11.4.0` (no caret) in `pubspec.yaml` to avoid needing SDK 37
- Or install SDK 37 via Android Studio SDK Manager and rename the folder from `android-37.0` to `android-37`

### App sensitivity too high in Neural Net mode
- Use the **NN Sensitivity** slider on the main screen (visible when Neural Net is active)
- Set it to **Low** or **Very Low** to ignore background conversations
- The slider is also available in Settings

### Bluetooth mic not switching automatically
- Ensure the device is paired and connected before starting monitoring
- Some BT devices take 1–2 seconds to open the SCO link — the 500 ms delay in `rerouteAudioRecord` handles this
- Check that the device shows a mic icon in your Bluetooth settings

---

## Dependencies

### Flutter / Dart
| Package | Version | Purpose |
|---|---|---|
| `permission_handler` | 11.4.0 | Runtime microphone permission |
| `shared_preferences` | ^2.3.0 | Settings persistence |

### Android
| Library | Version | Purpose |
|---|---|---|
| `com.google.mediapipe:tasks-audio` | 1.0.0 | YAMNet on-device inference |
| `com.google.android.play:feature-delivery` | 2.1.0 | Flutter deferred components support |

### iOS
| Framework | Purpose |
|---|---|
| `AVFoundation` | Audio engine, session management |
| `CoreML` | YAMNet on-device inference |
| `Accelerate` | Fast RMS calculation via vDSP |
