import 'dart:async';
import 'package:flutter/material.dart';
import 'audio_monitor_service.dart';
import 'settings_repository.dart';
import 'permission_helper.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late final AudioMonitorService _service;
  final _repo = SettingsRepository();
  bool _settingsLoaded = false;
  late final StreamSubscription<AwarenessState> _stateSub;
  late final StreamSubscription<int>            _countdownSub;
  late final StreamSubscription<int>            _amplitudeSub;
  late final StreamSubscription<MicSource>      _micSourceSub;
  late final StreamSubscription<MicMode>        _micModeSub;
  late final StreamSubscription<void>           _notifStopSub;
  late final StreamSubscription<DetectionMode>   _detectionModeSub;

  AwarenessState _state        = AwarenessState.idle;
  AwarenessState _displayState = AwarenessState.idle;

  bool      _isStarting         = false;
  int       _countdownRemaining = 0;
  int       _currentAmplitude   = 0;
  MicSource _micSource          = MicSource.builtin;
  MicMode        _micMode            = MicMode.auto;
  DetectionMode  _detectionMode      = DetectionMode.rms;

  Timer? _countdownDebounce;

  late final AnimationController _pulseController;
  late final Animation<double>   _pulseAnimation;

  // Settings
  int    _silenceTimeout = 3;
  double _duckedVolume   = 0.2;
  int    _voiceThreshold = 500;
  double _nnSensitivity  = 0.5;
  bool   _pauseAudio     = false;

  @override
  void initState() {
    super.initState();
    _service = AudioMonitorService();

    // Load persisted settings before subscribing to streams so the UI
    // shows the correct values from the first frame.
    _loadSettings();

    _stateSub = _service.stateStream.listen((s) {
      if (!mounted) return;
      setState(() => _state = s);

      if (s == AwarenessState.countdown) {
        _countdownDebounce?.cancel();
        _countdownDebounce = Timer(const Duration(milliseconds: 500), () {
          if (mounted && _state == AwarenessState.countdown) {
            setState(() => _displayState = AwarenessState.countdown);
          }
        });
      } else {
        _countdownDebounce?.cancel();
        _countdownDebounce = null;
        setState(() => _displayState = s);
      }
    });

    _countdownSub = _service.countdownStream.listen((remaining) {
      if (mounted) setState(() => _countdownRemaining = remaining);
    });

    _amplitudeSub = _service.amplitudeStream.listen((rms) {
      if (mounted) setState(() => _currentAmplitude = rms);
    });

    _micSourceSub = _service.micSourceStream.listen((src) {
      if (!mounted) return;
      final prev = _micSource;
      setState(() => _micSource = src);
      if (_state != AwarenessState.idle && src != prev) {
        final label = src == MicSource.bluetooth
            ? '🎧 Switched to Bluetooth mic'
            : src == MicSource.wired
            ? '🎧 Switched to wired headset mic'
            : '📱 Switched to built-in mic';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(label),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ));
      }
    });

    _micModeSub = _service.micModeStream.listen((mode) {
      if (mounted) setState(() => _micMode = mode);
    });

    _detectionModeSub = _service.detectionModeStream.listen((mode) {
      if (mounted) setState(() => _detectionMode = mode);
    });

    // When the user taps Stop in the background notification, the native
    // plugin stops monitoring and fires this event. We reset all transient
    // UI state so the home screen shows the Off state immediately.
    _notifStopSub = _service.stoppedFromNotifStream.listen((_) {
      if (!mounted) return;
      // The native plugin already stopped monitoring and emitted idle via
      // the state stream, but if the app was in the background the stream
      // listener may not have fired yet. Reset everything explicitly here
      // so the UI shows "Off" as soon as the user returns to the app.
      _countdownDebounce?.cancel();
      _countdownDebounce = null;
      setState(() {
        _state            = AwarenessState.idle;
        _displayState     = AwarenessState.idle;
        _currentAmplitude = 0;
        _micSource        = MicSource.builtin;
        // Keep _micMode and _detectionMode — they are user preferences.
      });
    });


    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.18).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _countdownDebounce?.cancel();
    _stateSub.cancel();
    _countdownSub.cancel();
    _amplitudeSub.cancel();
    _micSourceSub.cancel();
    _micModeSub.cancel();
    _detectionModeSub.cancel();
    _notifStopSub.cancel();
    _service.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // ── Settings persistence ──────────────────────────────────────────────────

  Future<void> _loadSettings() async {
    final s = await _repo.load();
    if (!mounted) return;
    setState(() {
      _silenceTimeout = s.silenceTimeout;
      _duckedVolume   = s.duckedVolume;
      _voiceThreshold = s.voiceThreshold;
      _detectionMode  = s.detectionMode;
      _micMode        = s.micMode;
      _nnSensitivity  = s.nnSensitivity;
      _pauseAudio     = s.pauseAudio;
      _settingsLoaded = true;
    });
  }

  /// Saves current settings to disk. Called whenever any setting changes.
  void _saveSettings() {
    _repo.save(AppSettings(
      silenceTimeout: _silenceTimeout,
      duckedVolume:   _duckedVolume,
      voiceThreshold: _voiceThreshold,
      detectionMode:  _detectionMode,
      micMode:        _micMode,
      nnSensitivity:  _nnSensitivity,
      pauseAudio:     _pauseAudio,
    ));
  }

  // ── Toggle ────────────────────────────────────────────────────────────────

  Future<void> _toggle() async {
    if (_isStarting) return;
    setState(() => _isStarting = true);
    try {
      if (_state == AwarenessState.idle) {
        final granted = await requestMicrophonePermission(context);
        if (!granted) { setState(() => _isStarting = false); return; }
        await _service.start(
          silenceTimeoutSeconds: _silenceTimeout,
          duckedVolumeFraction:  _duckedVolume,
          voiceThreshold:        _voiceThreshold,
          detectionMode:         _detectionMode,
          nnSensitivity:         _nnSensitivity,
          pauseAudio:            _pauseAudio,
        );
      } else {
        await _service.stop();
        if (mounted) setState(() {
          _currentAmplitude = 0;
          _micSource        = MicSource.builtin;
          // Do NOT reset _micMode or _detectionMode here —
          // they are user preferences and should survive a stop/start cycle.
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _isStarting = false);
    }
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

  Color get _stateColor {
    switch (_displayState) {
      case AwarenessState.idle:      return Colors.grey;
      case AwarenessState.listening: return const Color(0xFF4CAF50);
      case AwarenessState.active:    return const Color(0xFFFF9800);
      case AwarenessState.countdown: return const Color(0xFF2196F3);
    }
  }

  IconData get _stateIcon {
    switch (_displayState) {
      case AwarenessState.idle:      return Icons.mic_off;
      case AwarenessState.listening: return Icons.hearing;
      case AwarenessState.active:    return Icons.volume_down_rounded;
      case AwarenessState.countdown: return Icons.timer_outlined;
    }
  }

  String get _stateLabel {
    switch (_displayState) {
      case AwarenessState.idle:      return 'Off';
      case AwarenessState.listening: return 'Listening…';
      case AwarenessState.active:    return 'Voice detected — volume ducked';
      case AwarenessState.countdown: return 'Silence detected — restoring soon…';
    }
  }

  String get _stateDescription {
    switch (_displayState) {
      case AwarenessState.idle:
        return 'Tap the button below to start\nAmbient Audio.';
      case AwarenessState.listening:
        return 'Microphone is active. Speak to trigger\nvolume ducking.';
      case AwarenessState.active:
        return 'You are speaking! Media volume has\nbeen reduced so you can hear clearly.';
      case AwarenessState.countdown:
        if (_silenceTimeout == 0) return 'Restoring volume immediately…';
        final s = _countdownRemaining == 1 ? 'second' : 'seconds';
        return 'No voice detected.\nVolume restores in $_countdownRemaining $s…';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs        = Theme.of(context).colorScheme;
    final isRunning = _displayState != AwarenessState.idle;
    final isPulsing = _displayState == AwarenessState.active;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Ambient Audio',
            style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          if (isRunning)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _MicSourceChip(source: _micSource, mode: _micMode),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _showSettings(context),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          child: Column(
            children: [
              const Spacer(flex: 1),

              // ── Status ring ──────────────────────────────────────────
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (_, child) => Transform.scale(
                  scale: isPulsing ? _pulseAnimation.value : 1.0,
                  child: child,
                ),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOut,
                  width: 180, height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _stateColor.withOpacity(0.12),
                    border: Border.all(color: _stateColor, width: 3),
                    boxShadow: [BoxShadow(
                      color: _stateColor.withOpacity(0.35),
                      blurRadius: 32, spreadRadius: 4,
                    )],
                  ),
                  child: _displayState == AwarenessState.countdown && _silenceTimeout > 0
                      ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text('$_countdownRemaining', style: TextStyle(
                      fontSize: 64, fontWeight: FontWeight.w800,
                      color: _stateColor, height: 1.0,
                    )),
                    Text(
                      _countdownRemaining == 1 ? 'second' : 'seconds',
                      style: TextStyle(fontSize: 13,
                          color: _stateColor.withOpacity(0.8)),
                    ),
                  ])
                      : Icon(_stateIcon, size: 80, color: _stateColor),
                ),
              ),

              const SizedBox(height: 28),

              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(_stateLabel,
                  key: ValueKey(_displayState),
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600,
                      color: _stateColor),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 12),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(_stateDescription,
                  key: ValueKey((_displayState, _countdownRemaining)),
                  style: TextStyle(fontSize: 14,
                      color: cs.onSurface.withOpacity(0.6), height: 1.5),
                  textAlign: TextAlign.center,
                ),
              ),

              const SizedBox(height: 28),

              // ── Live noise meter / NN indicator ──────────────────
              if (isRunning)
                _detectionMode == DetectionMode.nn
                    ? _NNModeIndicator(
                  amplitude: _currentAmplitude,
                  sensitivity: _nnSensitivity,
                  onSensitivityChanged: (v) {
                    setState(() => _nnSensitivity = v);
                    _service.setNNSensitivity(v);
                    _saveSettings();
                  },
                )
                    : _NoiseMeter(
                  amplitude: _currentAmplitude,
                  threshold: _voiceThreshold,
                  onThresholdChanged: (v) {
                    setState(() => _voiceThreshold = v);
                    _service.setThreshold(v);
                    _saveSettings();
                  },
                ),

              const Spacer(flex: 2),

              // ── Info cards ───────────────────────────────────────────
              if (isRunning) ...[
                // Volume card: shows "Pause Audio: On" when pause mode is
                // active, otherwise shows the ducked volume percentage.
                _InfoCard(
                  icon: _pauseAudio
                      ? Icons.pause_circle_outline
                      : Icons.volume_down,
                  label: _pauseAudio ? 'Pause audio' : 'Ducked volume',
                  value: _pauseAudio
                      ? 'On'
                      : _duckedVolume == 0.0
                      ? 'Mute'
                      : '${(_duckedVolume * 100).round()}%',
                  color: _pauseAudio
                      ? const Color(0xFFE53935)
                      : const Color(0xFFFF9800),
                ),
                const SizedBox(height: 12),
                _InfoCard(
                  icon: Icons.timer,
                  label: 'Silence timeout',
                  value: _silenceTimeout == 0 ? 'Instant' : '${_silenceTimeout}s',
                  color: const Color(0xFF2196F3),
                ),
                const SizedBox(height: 32),
              ],

              // ── Toggle button ────────────────────────────────────────
              SizedBox(
                width: double.infinity, height: 56,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: LinearGradient(
                      colors: isRunning
                          ? [const Color(0xFFE53935), const Color(0xFFB71C1C)]
                          : [const Color(0xFF6750A4), const Color(0xFF4527A0)],
                    ),
                  ),
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: _isStarting ? null : _toggle,
                    icon: _isStarting
                        ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                        : Icon(isRunning
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded),
                    label: Text(
                      _isStarting ? 'Starting…'
                          : isRunning ? 'Stop' : 'Start Listening',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // ── Settings sheet ────────────────────────────────────────────────────────

  void _showSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,   // required for DraggableScrollableSheet
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      // Shape is applied inside DraggableScrollableSheet's builder instead.
      builder: (_) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: _SettingsSheet(
          silenceTimeout:   _silenceTimeout,
          duckedVolume:     _duckedVolume,
          voiceThreshold:   _voiceThreshold,
          isRunning:        _state != AwarenessState.idle,
          currentMicMode:   _micMode,
          currentMicSource: _micSource,
          currentDetectionMode: _detectionMode,
          service:          _service,
          nnSensitivity:    _nnSensitivity,
          pauseAudio:       _pauseAudio,
          onChanged: (timeout, volume, threshold, detMode) {
            setState(() {
              _silenceTimeout = timeout;
              _duckedVolume   = volume;
              _voiceThreshold = threshold;
              _detectionMode  = detMode;
            });
            if (_state != AwarenessState.idle) {
              _service.setThreshold(threshold);
              _service.setSettings(
                silenceTimeoutSeconds: timeout,
                duckedVolumeFraction: volume,
              );
            }
            _saveSettings();
          },
          onSensitivityChanged: (s) {
            setState(() => _nnSensitivity = s);
            _service.setNNSensitivity(s);
            _saveSettings();
          },
          onPauseAudioChanged: (v) {
            setState(() => _pauseAudio = v);
            _service.setPauseAudio(v);
            _saveSettings();
          },
          onMicModeChanged: (mode) {
            setState(() => _micMode = mode);
            _saveSettings();
          },
        ),
      ),
    );
  }
}

// ── Mic source chip ───────────────────────────────────────────────────────────

class _MicSourceChip extends StatelessWidget {
  const _MicSourceChip({required this.source, required this.mode});
  final MicSource source;
  final MicMode   mode;

  @override
  Widget build(BuildContext context) {
    final isBluetooth = source == MicSource.bluetooth;
    final isWired     = source == MicSource.wired;
    final isPinned    = mode != MicMode.auto;
    final color = isBluetooth
        ? const Color(0xFF2196F3)
        : isWired
        ? const Color(0xFF4CAF50)
        : Theme.of(context).colorScheme.onSurface.withOpacity(0.5);
    final icon = isBluetooth
        ? Icons.bluetooth_audio
        : isWired
        ? Icons.headset
        : Icons.mic;
    final label = isBluetooth ? 'BT Mic'
        : isWired     ? 'Wired Mic'
        :               'Built-in';

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: Container(
        key: ValueKey(source),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                color: color),
          ),
          if (isPinned) ...[
            const SizedBox(width: 3),
            Icon(Icons.push_pin, size: 10, color: color.withOpacity(0.8)),
          ],
        ]),
      ),
    );
  }
}

// ── Noise meter ───────────────────────────────────────────────────────────────

class _NoiseMeter extends StatelessWidget {
  const _NoiseMeter({
    required this.amplitude,
    required this.threshold,
    required this.onThresholdChanged,
  });

  final int amplitude;
  final int threshold;
  final ValueChanged<int> onThresholdChanged;

  static const int _maxRMS = 2000;

  @override
  Widget build(BuildContext context) {
    final cs       = Theme.of(context).colorScheme;
    final fillFrac = (amplitude / _maxRMS).clamp(0.0, 1.0);
    final thFrac   = (threshold  / _maxRMS).clamp(0.0, 1.0);
    final barColor = amplitude > threshold
        ? const Color(0xFFFF9800)
        : const Color(0xFF4CAF50);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.graphic_eq, size: 18,
            color: cs.onSurface.withOpacity(0.7)),
        const SizedBox(width: 8),
        Text('Noise level', style: TextStyle(fontWeight: FontWeight.w600,
            color: cs.onSurface.withOpacity(0.85))),
        const Spacer(),
        Text('RMS $amplitude', style: TextStyle(fontSize: 12,
            color: cs.onSurface.withOpacity(0.45))),
      ]),
      const SizedBox(height: 8),
      SizedBox(
        height: 28,
        child: LayoutBuilder(builder: (_, c) {
          final w = c.maxWidth;
          return Stack(children: [
            Container(decoration: BoxDecoration(
              color: cs.onSurface.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
            )),
            AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              width: w * fillFrac,
              decoration: BoxDecoration(
                color: barColor.withOpacity(0.85),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            Positioned(
              left: (w * thFrac).clamp(0.0, w - 2),
              top: 0, bottom: 0,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: [BoxShadow(
                      color: Colors.black.withOpacity(0.4), blurRadius: 4)],
                ),
              ),
            ),
          ]);
        }),
      ),
      const SizedBox(height: 4),
      Row(children: [
        Text('0', style: TextStyle(fontSize: 10,
            color: cs.onSurface.withOpacity(0.35))),
        const Spacer(),
        Text('Threshold: $threshold', style: TextStyle(fontSize: 10,
            color: cs.onSurface.withOpacity(0.45))),
        const Spacer(),
        Text('$_maxRMS', style: TextStyle(fontSize: 10,
            color: cs.onSurface.withOpacity(0.35))),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Icon(Icons.tune, size: 16, color: cs.onSurface.withOpacity(0.6)),
        const SizedBox(width: 6),
        Text('Threshold', style: TextStyle(fontSize: 13,
            color: cs.onSurface.withOpacity(0.7))),
        const Spacer(),
        Text('$threshold', style: const TextStyle(
            fontWeight: FontWeight.w700, color: Color(0xFF9C27B0))),
      ]),
      Slider(
        value: threshold.toDouble(),
        min: 0, max: _maxRMS.toDouble(), divisions: 40,
        activeColor: const Color(0xFF9C27B0),
        onChanged: (v) => onThresholdChanged(v.round()),
      ),
      Text('Drag so the white line sits just above your background noise.',
          style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.45))),
      const SizedBox(height: 8),
    ]);
  }
}

// ── Info card ─────────────────────────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon, required this.label,
    required this.value, required this.color,
  });
  final IconData icon;
  final String   label, value;
  final Color    color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 14),
        Text(label, style: TextStyle(color: cs.onSurface.withOpacity(0.7))),
        const Spacer(),
        Text(value, style: TextStyle(fontWeight: FontWeight.w700,
            fontSize: 16, color: color)),
      ]),
    );
  }
}

// ── Settings sheet ────────────────────────────────────────────────────────────

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.silenceTimeout,
    required this.duckedVolume,
    required this.voiceThreshold,
    required this.isRunning,
    required this.currentMicMode,
    required this.currentMicSource,
    required this.currentDetectionMode,
    required this.service,
    required this.onChanged,
    required this.nnSensitivity,
    required this.onSensitivityChanged,
    required this.pauseAudio,
    required this.onPauseAudioChanged,
    this.onMicModeChanged,
  });

  final int               silenceTimeout;
  final double            duckedVolume;
  final int               voiceThreshold;
  final bool              isRunning;
  final MicMode           currentMicMode;
  final MicSource         currentMicSource;
  final DetectionMode     currentDetectionMode;
  final double            nnSensitivity;
  final bool              pauseAudio;
  final AudioMonitorService service;
  final void Function(int timeout, double volume, int threshold, DetectionMode mode) onChanged;
  final void Function(double sensitivity) onSensitivityChanged;
  final void Function(bool enabled) onPauseAudioChanged;
  final void Function(MicMode mode)? onMicModeChanged;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late int           _timeout;
  late double        _volume;
  late int           _threshold;
  late MicMode       _micMode;
  late DetectionMode _detectionMode;
  late double        _sensitivity;
  late bool          _pauseAudio;

  bool _isChangingMic = false;
  String? _micError;

  static const int _maxRMS = 2000;

  @override
  void initState() {
    super.initState();
    _timeout        = widget.silenceTimeout;
    _volume         = widget.duckedVolume;
    _threshold      = widget.voiceThreshold;
    _micMode        = widget.currentMicMode;
    _detectionMode  = widget.currentDetectionMode;
    _sensitivity    = widget.nnSensitivity;
    _pauseAudio     = widget.pauseAudio;
  }

  void _notify() {
    widget.onChanged(_timeout, _volume, _threshold, _detectionMode);
  }

  Future<void> _changeMicMode(MicMode mode) async {
    setState(() { _isChangingMic = true; _micError = null; });
    try {
      await widget.service.setMicMode(mode);
      setState(() => _micMode = mode);
      widget.onMicModeChanged?.call(mode);
    } catch (e) {
      setState(() => _micError = e.toString().contains('NO_BT_MIC')
          ? 'No Bluetooth mic connected.'
          : 'Could not switch mic: $e');
    } finally {
      setState(() => _isChangingMic = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Helper to build a section header row consistently.
    Widget header(IconData icon, String label) => Row(children: [
      Icon(icon, size: 20, color: cs.onSurface.withOpacity(0.8)),
      const SizedBox(width: 10),
      Text(label, style: TextStyle(fontWeight: FontWeight.w600,
          fontSize: 15, color: cs.onSurface)),
    ]);

    // Helper for the hint text below each control.
    Widget hint(String text) => Text(text,
        style: TextStyle(fontSize: 12,
            height: 1.4, color: cs.onSurface.withOpacity(0.5)));

    // All settings are always editable — changes take effect live.
    // Silence timeout and ducked volume are applied on the next start
    // if the app is currently stopped; all others take effect immediately.

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, scrollController) => Column(
        children: [
          // ── Fixed handle + title (doesn't scroll) ─────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                )),
                const SizedBox(height: 16),
                Text('Settings', style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700,
                    color: cs.onSurface)),
                const SizedBox(height: 12),
                // Info banner — shown while running, updated to reflect
                // that all settings are now live-adjustable.
                if (widget.isRunning)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: cs.primary.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: cs.primary.withOpacity(0.25)),
                    ),
                    child: Row(children: [
                      Icon(Icons.info_outline, size: 16, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(child: Text(
                        'All settings take effect live. '
                            'Timeout and volume apply on the next voice event.',
                        style: TextStyle(fontSize: 12, color: cs.primary),
                      )),
                    ]),
                  ),
                const SizedBox(height: 4),
              ],
            ),
          ),

          // ── Scrollable body ────────────────────────────────────────
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
              children: [

                // ── Detection mode ──────────────────────────────────
                header(Icons.memory_outlined, 'Detection mode'),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: _DetectionModeButton(
                    label: 'RMS',
                    subtitle: 'Low battery',
                    icon: Icons.bolt,
                    selected: _detectionMode == DetectionMode.rms,
                    onTap: () async {
                      if (_detectionMode == DetectionMode.rms) return;
                      if (widget.isRunning) {
                        try {
                          await widget.service
                              .setDetectionMode(DetectionMode.rms);
                        } catch (_) {}
                      }
                      setState(() => _detectionMode = DetectionMode.rms);
                      _notify();
                    },
                  )),
                  const SizedBox(width: 10),
                  Expanded(child: _DetectionModeButton(
                    label: 'Neural Net',
                    subtitle: 'High accuracy',
                    icon: Icons.hub_outlined,
                    selected: _detectionMode == DetectionMode.nn,
                    onTap: () async {
                      if (_detectionMode == DetectionMode.nn) return;
                      if (widget.isRunning) {
                        try {
                          await widget.service
                              .setDetectionMode(DetectionMode.nn);
                        } on Exception catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    e.toString().contains('MODEL_ERROR')
                                        ? 'YAMNet model not found. See README.'
                                        : 'Could not switch mode: ${e}'),
                                backgroundColor:
                                Theme.of(context).colorScheme.error,
                              ),
                            );
                          }
                          return;
                        }
                      }
                      setState(() => _detectionMode = DetectionMode.nn);
                      _notify();
                    },
                  )),
                ]),
                const SizedBox(height: 8),
                hint(_detectionMode == DetectionMode.rms
                    ? 'Fast amplitude threshold. Minimal battery impact.'
                    : 'YAMNet AI identifies human speech. More accurate, higher battery usage.'),
                const SizedBox(height: 28),

                // ── NN Sensitivity (NN mode only) ───────────────────
                if (_detectionMode == DetectionMode.nn) ...[
                  header(Icons.tune_outlined, 'NN Sensitivity'),
                  const SizedBox(height: 4),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    Text(
                      _sensitivity >= 0.85 ? 'Very High'
                          : _sensitivity >= 0.65 ? 'High'
                          : _sensitivity >= 0.40 ? 'Medium'
                          : _sensitivity >= 0.20 ? 'Low'
                          : 'Very Low',
                      style: const TextStyle(
                          color: Color(0xFF009688),
                          fontWeight: FontWeight.w700),
                    ),
                  ]),
                  Slider(
                    value: _sensitivity,
                    min: 0.0, max: 1.0, divisions: 20,
                    activeColor: const Color(0xFF009688),
                    onChanged: (v) {
                      setState(() => _sensitivity = v);
                      widget.onSensitivityChanged(v);
                    },
                  ),
                  hint(_sensitivity >= 0.65
                      ? 'Detects quiet or distant voices. May trigger on background conversations.'
                      : _sensitivity >= 0.35
                      ? 'Balanced — works well for most environments.'
                      : 'Only detects close, clear speech. Ignores background voices.'),
                  const SizedBox(height: 28),
                ],

                // ── Microphone input ────────────────────────────────
                header(Icons.settings_input_component_outlined,
                    'Microphone input'),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: _MicModeButton(
                    label: 'Auto',
                    icon: Icons.autorenew,
                    selected: _micMode == MicMode.auto,
                    loading: _isChangingMic && _micMode != MicMode.auto,
                    onTap: widget.isRunning
                        ? () => _changeMicMode(MicMode.auto)
                        : () => setState(() => _micMode = MicMode.auto),
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: _MicModeButton(
                    label: 'Built-in',
                    icon: Icons.mic,
                    selected: _micMode == MicMode.builtin,
                    loading: _isChangingMic && _micMode == MicMode.builtin,
                    onTap: widget.isRunning
                        ? () => _changeMicMode(MicMode.builtin)
                        : () => setState(() => _micMode = MicMode.builtin),
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: _MicModeButton(
                    label: 'Bluetooth',
                    icon: Icons.bluetooth_audio,
                    selected: _micMode == MicMode.bluetooth,
                    loading: _isChangingMic && _micMode == MicMode.bluetooth,
                    onTap: widget.isRunning
                        ? () => _changeMicMode(MicMode.bluetooth)
                        : () => setState(() => _micMode = MicMode.bluetooth),
                  )),
                ]),
                if (_micError != null) ...[
                  const SizedBox(height: 8),
                  Text(_micError!,
                      style: TextStyle(fontSize: 12, color: cs.error)),
                ],
                const SizedBox(height: 8),
                hint(_micMode == MicMode.auto
                    ? 'Automatically uses Bluetooth when connected, built-in otherwise.'
                    : _micMode == MicMode.builtin
                    ? 'Always uses the built-in mic, even when Bluetooth is connected.'
                    : 'Always uses the Bluetooth mic. Falls back to built-in if disconnected.'),
                const SizedBox(height: 28),

                // ── Silence timeout ─────────────────────────────────
                header(Icons.timer_outlined, 'Silence timeout'),
                const SizedBox(height: 4),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Text(_timeout == 0 ? 'Instant' : '${_timeout}s',
                      style: const TextStyle(
                          color: Color(0xFF2196F3),
                          fontWeight: FontWeight.w700)),
                ]),
                Slider(
                  value: _timeout.toDouble(),
                  min: 0, max: 10, divisions: 10,
                  activeColor: const Color(0xFF2196F3),
                  // Always live — applied on the next silence event.
                  onChanged: (v) {
                    setState(() => _timeout = v.round()); _notify();
                  },
                ),
                hint(_timeout == 0
                    ? 'Volume restores the instant silence is detected.'
                    : 'How long the mic must be silent before volume restores.'),
                const SizedBox(height: 28),

                // ── Pause audio toggle ──────────────────────────────
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: cs.onSurface.withOpacity(0.1)),
                  ),
                  child: Row(children: [
                    Icon(Icons.pause_circle_outline,
                        size: 24,
                        color: _pauseAudio
                            ? const Color(0xFFE53935)
                            : cs.onSurface.withOpacity(0.55)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Pause audio', style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15, color: cs.onSurface)),
                          const SizedBox(height: 4),
                          hint(_pauseAudio
                              ? 'Pauses Spotify, YouTube, etc. when you speak.'
                              : 'Reduces volume when you speak.'),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Switch(
                      value: _pauseAudio,
                      activeColor: const Color(0xFFE53935),
                      onChanged: (v) {
                        setState(() => _pauseAudio = v);
                        widget.onPauseAudioChanged(v);
                      },
                    ),
                  ]),
                ),
                const SizedBox(height: 28),

                // ── Ducked volume (hidden when pause audio is on) ───
                if (!_pauseAudio) ...[
                  header(Icons.volume_down_outlined, 'Ducked volume'),
                  const SizedBox(height: 4),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    Text(_volume == 0.0 ? 'Mute' : '${(_volume * 100).round()}%',
                        style: const TextStyle(
                            color: Color(0xFFFF9800),
                            fontWeight: FontWeight.w700)),
                  ]),
                  Slider(
                    value: _volume,
                    min: 0.0, max: 0.95, divisions: 19,
                    activeColor: const Color(0xFFFF9800),
                    // Always live.
                    onChanged: (v) {
                      setState(() => _volume = v < 0.01 ? 0.0 : v);
                      _notify();
                    },
                  ),
                  hint(_volume == 0.0
                      ? 'Audio will be fully muted when your voice is detected.'
                      : 'How much volume to reduce to when your voice is detected.'),
                  const SizedBox(height: 28),
                ],

                // ── Voice threshold (RMS mode only) ─────────────────
                if (_detectionMode == DetectionMode.rms) ...[
                  header(Icons.tune, 'Voice threshold'),
                  const SizedBox(height: 4),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    Text('$_threshold', style: const TextStyle(
                        color: Color(0xFF9C27B0),
                        fontWeight: FontWeight.w700)),
                  ]),
                  Slider(
                    value: _threshold.toDouble(),
                    min: 0, max: _maxRMS.toDouble(), divisions: 40,
                    activeColor: const Color(0xFF9C27B0),
                    onChanged: (v) {
                      setState(() => _threshold = v.round()); _notify();
                    },
                  ),
                  hint('Higher = less sensitive. Use the live meter on the main screen to calibrate.'),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cs.primary.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: cs.primary.withOpacity(0.2)),
                    ),
                    child: Row(children: [
                      Icon(Icons.hub_outlined, size: 18, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(child: Text(
                        'Neural Net mode uses AI classification — '
                            'the volume threshold is not used.',
                        style: TextStyle(fontSize: 12, color: cs.primary),
                      )),
                    ]),
                  ),
                ],

              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Mic mode button (used in the three-way selector) ─────────────────────────

class _MicModeButton extends StatelessWidget {
  const _MicModeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.loading,
    required this.onTap,
  });

  final String   label;
  final IconData icon;
  final bool     selected;
  final bool     loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs    = Theme.of(context).colorScheme;
    final color = selected ? cs.primary : cs.onSurface.withOpacity(0.4);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withOpacity(0.12)
              : cs.onSurface.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? cs.primary : cs.onSurface.withOpacity(0.15),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          loading
              ? SizedBox(width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: color))
              : Icon(icon, size: 20, color: color),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
        ]),
      ),
    );
  }
}

// ── Detection mode button ─────────────────────────────────────────────────────

class _DetectionModeButton extends StatelessWidget {
  const _DetectionModeButton({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String   label;
  final String   subtitle;
  final IconData icon;
  final bool     selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs    = Theme.of(context).colorScheme;
    final color = selected ? cs.primary : cs.onSurface.withOpacity(0.4);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withOpacity(0.12)
              : cs.onSurface.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? cs.primary : cs.onSurface.withOpacity(0.15),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 24, color: color),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(
              fontSize: 10, color: color.withOpacity(0.8))),
        ]),
      ),
    );
  }
}

// ── NN mode indicator (replaces the noise meter in Neural Net mode) ───────────
// Includes the sensitivity slider so it is accessible without opening settings.

class _NNModeIndicator extends StatelessWidget {
  const _NNModeIndicator({
    required this.amplitude,
    required this.sensitivity,
    required this.onSensitivityChanged,
  });

  final int      amplitude;
  final double   sensitivity;
  final ValueChanged<double> onSensitivityChanged;

  static const int _maxRMS = 2000;

  String get _sensitivityLabel {
    if (sensitivity >= 0.85) return 'Very High';
    if (sensitivity >= 0.65) return 'High';
    if (sensitivity >= 0.40) return 'Medium';
    if (sensitivity >= 0.20) return 'Low';
    return 'Very Low';
  }

  String get _sensitivityHint {
    if (sensitivity >= 0.65) return 'May trigger on background conversations.';
    if (sensitivity >= 0.35) return 'Balanced — works well for most environments.';
    return 'Only detects close, clear speech.';
  }

  @override
  Widget build(BuildContext context) {
    final cs       = Theme.of(context).colorScheme;
    final fillFrac = (amplitude / _maxRMS).clamp(0.0, 1.0);
    final barColor = cs.primary.withOpacity(0.7);
    const tealColor = Color(0xFF009688);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ── Energy bar header ──────────────────────────────────────────
      Row(children: [
        Icon(Icons.hub_outlined, size: 18, color: cs.primary),
        const SizedBox(width: 8),
        Text('Neural Net active',
            style: TextStyle(fontWeight: FontWeight.w600, color: cs.primary)),
        const Spacer(),
        Text('RMS $amplitude',
            style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.45))),
      ]),
      const SizedBox(height: 8),

      // ── Raw energy bar ─────────────────────────────────────────────
      SizedBox(
        height: 28,
        child: LayoutBuilder(builder: (_, c) {
          final w = c.maxWidth;
          return Stack(children: [
            Container(decoration: BoxDecoration(
              color: cs.onSurface.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
            )),
            AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              width: w * fillFrac,
              decoration: BoxDecoration(
                color: barColor,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ]);
        }),
      ),
      const SizedBox(height: 6),
      Text(
        'YAMNet classifies audio in real time. '
            'Adjust sensitivity below.',
        style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.45)),
      ),

      const SizedBox(height: 14),

      // ── Sensitivity slider ─────────────────────────────────────────
      Row(children: [
        const Icon(Icons.tune_outlined, size: 18, color: tealColor),
        const SizedBox(width: 8),
        Text('NN Sensitivity',
            style: TextStyle(fontWeight: FontWeight.w600,
                color: cs.onSurface.withOpacity(0.85))),
        const Spacer(),
        Text(_sensitivityLabel,
            style: const TextStyle(
                fontWeight: FontWeight.w700, color: tealColor)),
      ]),
      Slider(
        value: sensitivity,
        min: 0.0,
        max: 1.0,
        divisions: 20,
        activeColor: tealColor,
        onChanged: onSensitivityChanged,
      ),
      Text(
        _sensitivityHint,
        style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.45)),
      ),
      const SizedBox(height: 8),
    ]);
  }
}