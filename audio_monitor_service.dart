import 'dart:async';
import 'package:flutter/services.dart';

enum AwarenessState { idle, listening, active, countdown }
enum MicSource { builtin, bluetooth, wired }
enum MicMode { auto, bluetooth, builtin }

/// Which voice detection algorithm is active.
enum DetectionMode {
  /// Fast RMS amplitude threshold — low battery, instant response.
  rms,
  /// YAMNet neural network — higher accuracy, ~200ms latency, more battery.
  nn,
}

class InputDevice {
  final int    id;
  final String name;
  final int    type;
  final bool   isBluetooth;
  final bool   isBuiltin;

  const InputDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.isBluetooth,
    required this.isBuiltin,
  });

  factory InputDevice.fromMap(Map m) => InputDevice(
    id:          m['id']          as int,
    name:        m['name']        as String,
    type:        m['type']        as int,
    isBluetooth: m['isBluetooth'] as bool,
    isBuiltin:   m['isBuiltin']   as bool,
  );
}

class AudioMonitorService {
  static const _channel = MethodChannel('com.example.conversation_awareness/audio');

  final _stateController         = StreamController<AwarenessState>.broadcast();
  final _stoppedFromNotifController = StreamController<void>.broadcast();
  final _countdownController     = StreamController<int>.broadcast();
  final _amplitudeController     = StreamController<int>.broadcast();
  final _micSourceController     = StreamController<MicSource>.broadcast();
  final _micModeController       = StreamController<MicMode>.broadcast();
  final _detectionModeController = StreamController<DetectionMode>.broadcast();

  Stream<AwarenessState> get stateStream          => _stateController.stream;
  /// Fires when the user taps Stop in the background notification.
  Stream<void>           get stoppedFromNotifStream => _stoppedFromNotifController.stream;
  Stream<int>            get countdownStream       => _countdownController.stream;
  Stream<int>            get amplitudeStream       => _amplitudeController.stream;
  Stream<MicSource>      get micSourceStream       => _micSourceController.stream;
  Stream<MicMode>        get micModeStream         => _micModeController.stream;
  Stream<DetectionMode>  get detectionModeStream   => _detectionModeController.stream;
  /// Fires when the user taps Stop in the background notification.

  AwarenessState _currentState  = AwarenessState.idle;
  MicSource      _micSource     = MicSource.builtin;
  MicMode        _micMode       = MicMode.auto;
  DetectionMode  _detectionMode = DetectionMode.rms;

  AwarenessState get currentState  => _currentState;
  MicSource      get micSource     => _micSource;
  MicMode        get micMode       => _micMode;
  DetectionMode  get detectionMode => _detectionMode;

  AudioMonitorService() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<void> start({
    required int           silenceTimeoutSeconds,
    required double        duckedVolumeFraction,
    required int           voiceThreshold,
    required DetectionMode detectionMode,
    required double        nnSensitivity,
    required bool          pauseAudio,
  }) async {
    try {
      await _channel.invokeMethod('startMonitoring', {
        'silenceTimeoutSeconds': silenceTimeoutSeconds,
        'duckedVolumeFraction':  duckedVolumeFraction,
        'voiceThreshold':        voiceThreshold,
        'detectionMode':         detectionMode == DetectionMode.nn ? 'nn' : 'rms',
        'nnSensitivity':         nnSensitivity,
        'pauseAudio':            pauseAudio,
      });
      _emit(AwarenessState.listening);
    } on PlatformException catch (e) {
      debugPrint('start error: ${e.message}');
      rethrow;
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopMonitoring');
    } on PlatformException catch (e) {
      debugPrint('stop error: ${e.message}');
    } finally {
      _emit(AwarenessState.idle);
    }
  }

  Future<void> setThreshold(int threshold) async {
    try {
      await _channel.invokeMethod('setThreshold', {'voiceThreshold': threshold});
    } on PlatformException catch (e) {
      debugPrint('setThreshold error: ${e.message}');
    }
  }

  /// Live-update silence timeout and ducked volume without restarting.
  Future<void> setSettings({int? silenceTimeoutSeconds, double? duckedVolumeFraction}) async {
    final args = <String, dynamic>{};
    if (silenceTimeoutSeconds != null) args['silenceTimeoutSeconds'] = silenceTimeoutSeconds;
    if (duckedVolumeFraction  != null) args['duckedVolumeFraction']  = duckedVolumeFraction;
    if (args.isEmpty) return;
    try {
      await _channel.invokeMethod('setSettings', args);
    } on PlatformException catch (e) {
      debugPrint('setSettings error: \${e.message}');
    }
  }

  /// Toggle the pause-audio feature live without restarting monitoring.
  Future<void> setPauseAudio(bool enabled) async {
    try {
      await _channel.invokeMethod('setPauseAudio', {'enabled': enabled});
    } on PlatformException catch (e) {
      debugPrint('setPauseAudio error: \${e.message}');
    }
  }

  /// Update NN sensitivity live (0.0 = least sensitive, 1.0 = most sensitive).
  Future<void> setNNSensitivity(double sensitivity) async {
    try {
      await _channel.invokeMethod('setNNSensitivity', {
        'sensitivity': sensitivity.clamp(0.0, 1.0),
      });
    } on PlatformException catch (e) {
      debugPrint('setNNSensitivity error: ${e.message}');
    }
  }

  /// Switch detection mode live. Throws [PlatformException] with code
  /// "MODEL_ERROR" if NN mode is selected but the model file is missing.
  Future<void> setDetectionMode(DetectionMode mode) async {
    await _channel.invokeMethod('setDetectionMode', {
      'mode': mode == DetectionMode.nn ? 'nn' : 'rms',
    });
  }

  Future<void> setMicMode(MicMode mode) async {
    final label = mode == MicMode.bluetooth ? 'bluetooth'
        : mode == MicMode.builtin   ? 'builtin'
        : 'auto';
    await _channel.invokeMethod('setMicMode', {'mode': label});
  }

  Future<List<InputDevice>> getInputDevices() async {
    try {
      final raw = await _channel.invokeMethod('getInputDevices') as List;
      return raw.map((e) => InputDevice.fromMap(e as Map)).toList();
    } on PlatformException catch (e) {
      debugPrint('getInputDevices error: ${e.message}');
      return [];
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onVoiceDetected':
        _emit(AwarenessState.active);
        break;
      case 'onSilenceCountdown':
        final remaining = call.arguments as int? ?? 0;
        _emit(AwarenessState.countdown);
        if (!_countdownController.isClosed) _countdownController.add(remaining);
        break;
      case 'onSilenceRestored':
        _emit(AwarenessState.listening);
        break;
      case 'onAmplitude':
        final rms = call.arguments as int? ?? 0;
        if (!_amplitudeController.isClosed) _amplitudeController.add(rms);
        break;
      case 'onMicSource':
        final src = call.arguments as String? ?? 'builtin';
        _micSource = src == 'bluetooth' ? MicSource.bluetooth
            : src == 'wired'     ? MicSource.wired
            :                      MicSource.builtin;
        if (!_micSourceController.isClosed) _micSourceController.add(_micSource);
        break;
      case 'onMicMode':
        final m = call.arguments as String? ?? 'auto';
        _micMode = m == 'bluetooth' ? MicMode.bluetooth
            : m == 'builtin'   ? MicMode.builtin
            : MicMode.auto;
        if (!_micModeController.isClosed) _micModeController.add(_micMode);
        break;
      case 'onDetectionMode':
        final dm = call.arguments as String? ?? 'rms';
        _detectionMode = dm == 'nn' ? DetectionMode.nn : DetectionMode.rms;
        if (!_detectionModeController.isClosed) {
          _detectionModeController.add(_detectionMode);
        }
        break;
      case 'onMicError':
        debugPrint('Mic error: \${call.arguments}');
        break;
      case 'onStoppedFromNotification':
      // The user tapped Stop in the notification shade. Update our local
      // state so Flutter sees the service as stopped.
        _emit(AwarenessState.idle);
        break;
      default:
        debugPrint('Unknown native call: ${call.method}');
    }
  }

  void _emit(AwarenessState state) {
    _currentState = state;
    if (!_stateController.isClosed) _stateController.add(state);
  }

  void dispose() {
    _stateController.close();
    _stoppedFromNotifController.close();
    _countdownController.close();
    _amplitudeController.close();
    _micSourceController.close();
    _micModeController.close();
    _detectionModeController.close();
  }
}

void debugPrint(String msg) {
  assert(() {
    // ignore: avoid_print
    print('[AudioMonitorService] $msg');
    return true;
  }());
}