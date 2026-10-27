# Conversation Awareness — Android (Flutter)

A Flutter/Android app that mimics AirPods' Conversation Awareness feature on **any Android device or headphones**. When the microphone detects your voice, the media volume is automatically reduced so you can hear yourself speak. When silence is detected for a configurable timeout (default 3 seconds), the volume is restored.

---

## How It Works

```
Mic amplitude polling (every 100 ms)
       │
       ▼
Amplitude > threshold?
  ┌── YES ──► Duck media volume  ──► notify Flutter → "Voice detected" UI
  │
  └── NO  ──► Was voice active?
                ┌── YES ──► Start silence countdown
                │              └── Timeout reached? ──► Restore volume → "Listening" UI
                └── NO  ──► (already quiet, do nothing)
```

**Components:**

| File | Role |
|---|---|
| `lib/main.dart` | App entry point |
| `lib/home_screen.dart` | Main UI with state display, controls, and settings |
| `lib/audio_monitor_service.dart` | Dart-side MethodChannel wrapper; owns the state stream |
| `lib/permission_helper.dart` | Runtime RECORD_AUDIO permission request flow |
| `android/.../ConversationAwarenessPlugin.kt` | Native plugin: MediaRecorder amplitude polling + AudioManager volume control |
| `android/.../MainActivity.kt` | FlutterActivity that registers the plugin |
| `android/.../AndroidManifest.xml` | Declares RECORD_AUDIO + MODIFY_AUDIO_SETTINGS permissions |

---

## Prerequisites

- **Flutter SDK** ≥ 3.10 ([install guide](https://docs.flutter.dev/get-started/install))
- **Android Studio** Hedgehog (2023.1) or later
- Android SDK with API level 21+ (Android 5.0+)
- A physical Android device **or** emulator with microphone access
  > ⚠️ The emulator mic may not respond to room audio — a physical device gives the best experience.

---

## Setup Steps

### 1. Create a New Flutter Project

In Android Studio:
1. **File → New → New Flutter Project**
2. Select **Flutter Application**
3. Set the package name to `com.device_tools.conversation_awareness`
4. Choose **Kotlin** as the Android language
5. Click **Finish**

### 2. Replace Generated Files

Copy all files from this project into your new project, replacing the defaults:

```
your_project/
├── lib/
│   ├── main.dart                    ← replace
│   ├── home_screen.dart             ← add new
│   ├── audio_monitor_service.dart   ← add new
│   └── permission_helper.dart       ← add new
├── android/app/src/main/
│   ├── kotlin/com/example/conversation_awareness/
│   │   ├── MainActivity.kt          ← replace
│   │   └── ConversationAwarenessPlugin.kt  ← add new
│   ├── AndroidManifest.xml          ← replace
│   └── res/values/styles.xml        ← replace
├── android/app/build.gradle         ← replace
└── pubspec.yaml                     ← replace
```

### 3. Install Dependencies

```bash
flutter pub get
```

### 4. Run on Device

Connect your Android device (USB debugging enabled) and run:

```bash
flutter run
```

Or press the ▶ Run button in Android Studio after selecting your device.

---

## Permissions

The app requests two permissions:

| Permission | Why |
|---|---|
| `RECORD_AUDIO` | Read microphone amplitude to detect speech |
| `MODIFY_AUDIO_SETTINGS` | Adjust the media stream volume |

`RECORD_AUDIO` is a **dangerous permission** — Android will show a runtime prompt on first launch. The app handles denial gracefully with a rationale dialog.

---

## Configurable Settings

Access via the ⚙️ icon in the top-right corner:

| Setting | Default | Range | Description |
|---|---|---|---|
| Silence timeout | 3 s | 1–10 s | Silence duration before volume restores |
| Ducked volume | 20% | 5–80% | Target media volume when voice is detected |

> Settings can only be changed while monitoring is **stopped**.

---

## Tuning the Voice Threshold

The sensitivity of voice detection is controlled by `VOICE_THRESHOLD` in `ConversationAwarenessPlugin.kt`:

```kotlin
private const val VOICE_THRESHOLD = 500  // 0–32767 range
```

- **Lower value** → more sensitive (triggers on quiet speech or background noise)
- **Higher value** → less sensitive (only triggers on louder speech)

Typical values:
- Quiet environment: `300–500`
- Noisy environment: `800–1500`

---

## Architecture Notes

- **MethodChannel** is used for bidirectional native ↔ Flutter communication.
  - Flutter calls `startMonitoring` / `stopMonitoring` on the native side.
  - Native pushes `onVoiceDetected`, `onSilenceCountdown`, `onSilenceRestored` events back to Flutter.
- `MediaRecorder` is used **only** for amplitude polling — audio is discarded (`/dev/null`).
- Volume is managed via `AudioManager.STREAM_MUSIC` (the media stream).
- The original volume is saved before ducking and restored exactly afterwards.

---

## Known Limitations

- Volume control affects `STREAM_MUSIC` only (music, videos, podcasts). Ringtone and alarm streams are unaffected.
- On some Android 12+ devices, `MediaRecorder` may require the app to have microphone indicator acknowledgement before recording starts.
- Background operation is not implemented in this demo — the app must be in the foreground.

---

## Next Steps / Extensions

- [ ] **Foreground service** — keep monitoring when the screen is off
- [ ] **Bluetooth headphone detection** — trigger only when headphones are connected
- [ ] **Adaptive threshold** — auto-calibrate to ambient noise level
- [ ] **Quick Settings tile** — toggle from the notification shade
- [ ] **iOS support** — use `AVAudioEngine` via a platform channel
