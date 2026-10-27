import 'package:shared_preferences/shared_preferences.dart';
import 'audio_monitor_service.dart';

/// Persists all user settings across app restarts using SharedPreferences.
///
/// Call [load] once on startup to retrieve saved values, then call [save]
/// whenever any setting changes. Both methods are safe to call from any
/// async context.
class SettingsRepository {
  // SharedPreferences keys — never change these strings once shipped,
  // or existing users will lose their saved settings on update.
  static const _kSilenceTimeout  = 'silence_timeout_seconds';
  static const _kDuckedVolume    = 'ducked_volume_fraction';
  static const _kVoiceThreshold  = 'voice_threshold';
  static const _kDetectionMode   = 'detection_mode';
  static const _kMicMode         = 'mic_mode';
  static const _kNNSensitivity   = 'nn_sensitivity';
  static const _kPauseAudio      = 'pause_audio';

  // Default values — must match the initial values in home_screen.dart.
  static const defaultSilenceTimeout = 3;
  static const defaultDuckedVolume   = 0.2;
  static const defaultVoiceThreshold = 500;
  static const defaultDetectionMode  = DetectionMode.rms;
  static const defaultMicMode        = MicMode.auto;
  static const defaultNNSensitivity  = 0.50;
  static const defaultPauseAudio     = false;

  /// Loads all settings from disk. Returns defaults for any key not yet saved.
  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      silenceTimeout: prefs.getInt(_kSilenceTimeout)    ?? defaultSilenceTimeout,
      duckedVolume:   prefs.getDouble(_kDuckedVolume)   ?? defaultDuckedVolume,
      voiceThreshold: prefs.getInt(_kVoiceThreshold)    ?? defaultVoiceThreshold,
      detectionMode:  _parseDetectionMode(
          prefs.getString(_kDetectionMode)),
      micMode:        _parseMicMode(
          prefs.getString(_kMicMode)),
      nnSensitivity:  prefs.getDouble(_kNNSensitivity) ?? defaultNNSensitivity,
      pauseAudio:     prefs.getBool(_kPauseAudio)     ?? defaultPauseAudio,
    );
  }

  /// Persists all settings to disk. Call this whenever any value changes.
  Future<void> save(AppSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setInt(   _kSilenceTimeout, s.silenceTimeout),
      prefs.setDouble(_kDuckedVolume,   s.duckedVolume),
      prefs.setInt(   _kVoiceThreshold, s.voiceThreshold),
      prefs.setString(_kDetectionMode,
          s.detectionMode == DetectionMode.nn ? 'nn' : 'rms'),
      prefs.setString(_kMicMode,        _micModeLabel(s.micMode)),
      prefs.setDouble(_kNNSensitivity, s.nnSensitivity),
      prefs.setBool(  _kPauseAudio,    s.pauseAudio),
    ]);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static DetectionMode _parseDetectionMode(String? raw) =>
      raw == 'nn' ? DetectionMode.nn : DetectionMode.rms;

  static MicMode _parseMicMode(String? raw) {
    switch (raw) {
      case 'bluetooth': return MicMode.bluetooth;
      case 'builtin':   return MicMode.builtin;
      default:          return MicMode.auto;
    }
  }

  static String _micModeLabel(MicMode m) {
    switch (m) {
      case MicMode.bluetooth: return 'bluetooth';
      case MicMode.builtin:   return 'builtin';
      case MicMode.auto:      return 'auto';
    }
  }
}

/// Immutable snapshot of all user-configurable settings.
class AppSettings {
  final int           silenceTimeout;
  final double        duckedVolume;
  final int           voiceThreshold;
  final DetectionMode detectionMode;
  final MicMode       micMode;
  final double        nnSensitivity;
  final bool          pauseAudio;

  const AppSettings({
    required this.silenceTimeout,
    required this.duckedVolume,
    required this.voiceThreshold,
    required this.detectionMode,
    required this.micMode,
    required this.nnSensitivity,
    required this.pauseAudio,
  });

  AppSettings copyWith({
    int?           silenceTimeout,
    double?        duckedVolume,
    int?           voiceThreshold,
    DetectionMode? detectionMode,
    MicMode?       micMode,
    double?        nnSensitivity,
    bool?          pauseAudio,
  }) => AppSettings(
    silenceTimeout: silenceTimeout ?? this.silenceTimeout,
    duckedVolume:   duckedVolume   ?? this.duckedVolume,
    voiceThreshold: voiceThreshold ?? this.voiceThreshold,
    detectionMode:  detectionMode  ?? this.detectionMode,
    micMode:        micMode        ?? this.micMode,
    nnSensitivity:  nnSensitivity  ?? this.nnSensitivity,
    pauseAudio:     pauseAudio     ?? this.pauseAudio,
  );
}