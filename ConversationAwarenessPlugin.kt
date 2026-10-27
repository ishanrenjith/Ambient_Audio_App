package com.device_tools.conversation_awareness

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlin.math.sqrt

class ConversationAwarenessPlugin : FlutterPlugin, MethodCallHandler {

    companion object {
        private const val CHANNEL = "com.example.conversation_awareness/audio"

        private const val SAMPLE_RATE    = 16000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT   = AudioFormat.ENCODING_PCM_16BIT

        private const val METER_INTERVAL_MS = 80L

        // RMS mode: 4 consecutive polls above threshold to confirm voice.
        private const val VOICE_CONFIRM_POLLS = 4

        private val BLUETOOTH_MIC_TYPES = setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
        private val BUILTIN_MIC_TYPES = setOf(
            AudioDeviceInfo.TYPE_BUILTIN_MIC,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
        )
    }

    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    private val mainHandler = Handler(Looper.getMainLooper())

    private var audioRecord:     AudioRecord? = null
    private var recordingThread: Thread?      = null
    private var audioManager:    AudioManager? = null

    // ── Detection mode ────────────────────────────────────────────────────────
    // "rms" = fast amplitude threshold (original, low battery)
    // "nn"  = YAMNet neural network (higher accuracy, more battery)
    @Volatile private var detectionMode: String = "rms"
    private var voiceDetector: VoiceDetector? = null

    // Ring buffer holding the last 975 ms of audio for NN inference.
    // YAMNet needs exactly INPUT_SAMPLES = 15600 samples.
    private val nnRingBuffer = ShortArray(VoiceDetector.INPUT_SAMPLES)
    private var nnRingWritePos = 0
    private var nnRingFilled   = false

    // Settings
    private var voiceThreshold:        Int    = 500
    private var duckedVolumeFraction:  Double = 0.2
    private var silenceTimeoutSeconds: Int    = 3
    // NN sensitivity: 0.0 (least sensitive) – 1.0 (most sensitive). Default 0.5.
    private var nnSensitivity:         Float  = 0.50f
    // When true, requests audio focus to pause other apps instead of just ducking.
    private var pauseAudioEnabled:     Boolean = false
    private var audioFocusRequest:     AudioFocusRequest? = null
    private var hadAudioFocus:         Boolean = false

    // Volume
    private var originalVolume: Int = -1

    // State
    private var isVoiceActive:        Boolean = false
    private var isInCountdown:        Boolean = false
    private var silenceStartTime:     Long    = 0L
    private var lastCountdownSecond:  Int     = -1
    private var lastMeterSendTime:    Long    = 0L
    private var consecutiveVoicePolls: Int    = 0

    @Volatile private var isMonitoring = false

    // ── Mic routing ───────────────────────────────────────────────────────────
    private var preferredMicMode:  String          = "auto"
    private var pinnedDevice:      AudioDeviceInfo? = null
    private var bluetoothMicConnected               = false

    // Tracks whether a wired headset mic is connected.
    private var wiredMicConnected = false

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            // ── Bluetooth mic connected ──────────────────────────────────────
            val hasBluetoothMic = addedDevices.any {
                it.type in BLUETOOTH_MIC_TYPES && it.isSource }
            if (hasBluetoothMic && isMonitoring && !bluetoothMicConnected) {
                bluetoothMicConnected = true
                if (preferredMicMode == "auto") {
                    // BT takes priority over wired in auto mode.
                    mainHandler.postDelayed({ rerouteAudioRecord(toBlue = true) }, 500L)
                }
            }

            // ── Wired headset connected ──────────────────────────────────────
            val hasWiredMic = addedDevices.any {
                it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET && it.isSource }
            if (hasWiredMic && isMonitoring && !wiredMicConnected
                && !bluetoothMicConnected) {
                wiredMicConnected = true
                if (preferredMicMode == "auto") {
                    // Small delay so the OS finishes routing before we open AudioRecord.
                    mainHandler.postDelayed({ rerouteToWired() }, 300L)
                }
            }
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            // ── Bluetooth mic removed ────────────────────────────────────────
            val hadBt = removedDevices.any {
                it.type in BLUETOOTH_MIC_TYPES && it.isSource }
            if (hadBt && isMonitoring && bluetoothMicConnected) {
                bluetoothMicConnected = false
                pinnedDevice = null
                // Fall back to wired if still connected, otherwise built-in.
                if (wiredMicConnected && preferredMicMode == "auto") {
                    rerouteToWired()
                } else {
                    rerouteAudioRecord(toBlue = false)
                }
                if (preferredMicMode == "bluetooth") {
                    preferredMicMode = "auto"
                    notifyFlutter("onMicMode", "auto")
                }
            }

            // ── Wired headset removed ────────────────────────────────────────
            val hadWired = removedDevices.any {
                it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET && it.isSource }
            if (hadWired && isMonitoring && wiredMicConnected) {
                wiredMicConnected = false
                pinnedDevice = null
                // Restore normal audio mode now that the headset is gone.
                audioManager?.mode = AudioManager.MODE_NORMAL
                if (preferredMicMode == "auto" && !bluetoothMicConnected) {
                    // Fall back to built-in mic.
                    rerouteAudioRecord(toBlue = false)
                }
            }
        }
    }

    // ── BroadcastReceiver for notification Stop button ────────────────────────
    // When the user taps Stop in the notification shade, the service
    // broadcasts ACTION_STOP_MONITORING. We receive it here, stop monitoring
    // cleanly, and tell Flutter to update the UI.
    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == ConversationForegroundService.ACTION_STOP_MONITORING) {
                stopMonitoring()
                // Notify Flutter so the UI switches back to the "Off" state.
                mainHandler.post {
                    channel.invokeMethod("onStoppedFromNotification", null)
                }
            }
        }
    }
    private var receiverRegistered = false

    // ────────────────────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context      = binding.applicationContext
        channel      = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // Register the broadcast receiver for the notification Stop button.
        val filter = IntentFilter(ConversationForegroundService.ACTION_STOP_MONITORING)
        context.registerReceiver(stopReceiver, filter,
            Context.RECEIVER_NOT_EXPORTED)
        receiverRegistered = true
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        stopMonitoring()
        if (receiverRegistered) {
            try { context.unregisterReceiver(stopReceiver) } catch (_: Exception) {}
            receiverRegistered = false
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startMonitoring" -> {
                val timeout     = call.argument<Int>("silenceTimeoutSeconds") ?: 3
                val ducked      = call.argument<Double>("duckedVolumeFraction") ?: 0.2
                val threshold   = call.argument<Int>("voiceThreshold") ?: 500
                val mode        = call.argument<String>("detectionMode") ?: "rms"
                val sensitivity = call.argument<Double>("nnSensitivity")?.toFloat() ?: nnSensitivity
                nnSensitivity   = sensitivity.coerceIn(0f, 1f)
                pauseAudioEnabled = call.argument<Boolean>("pauseAudio") ?: pauseAudioEnabled
                startMonitoring(timeout, ducked, threshold, mode, result)
            }
            "stopMonitoring" -> {
                stopMonitoring()
                result.success(null)
            }
            "setThreshold" -> {
                voiceThreshold = call.argument<Int>("voiceThreshold") ?: voiceThreshold
                result.success(null)
            }
            // Switch detection mode live without restarting the recorder.
            "setDetectionMode" -> {
                val mode = call.argument<String>("mode") ?: "rms"
                setDetectionMode(mode, result)
            }
            "setMicMode" -> {
                val mode = call.argument<String>("mode") ?: "auto"
                setMicMode(mode, result)
            }
            "setNNSensitivity" -> {
                val s = call.argument<Double>("sensitivity")?.toFloat() ?: nnSensitivity
                nnSensitivity = s.coerceIn(0f, 1f)
                voiceDetector?.speechThreshold = VoiceDetector.sensitivityToThreshold(nnSensitivity)
                result.success(null)
            }
            "setSettings" -> {
                // Live-update silence timeout and ducked volume without restart.
                call.argument<Int>("silenceTimeoutSeconds")?.let {
                    silenceTimeoutSeconds = it
                }
                call.argument<Double>("duckedVolumeFraction")?.let {
                    duckedVolumeFraction = it
                    // If voice is currently active, re-apply the new duck level.
                    if (isVoiceActive && !pauseAudioEnabled) {
                        val am = audioManager ?: return
                        val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        val duckedVol = (maxVol * duckedVolumeFraction).toInt().coerceAtLeast(0)
                        am.setStreamVolume(AudioManager.STREAM_MUSIC, duckedVol, 0)
                    }
                }
                result.success(null)
            }
            "setPauseAudio" -> {
                pauseAudioEnabled = call.argument<Boolean>("enabled") ?: pauseAudioEnabled
                // If monitoring and voice is active, apply change immediately.
                if (isMonitoring && isVoiceActive) {
                    if (pauseAudioEnabled) requestAudioFocus()
                    else abandonAudioFocus()
                }
                result.success(null)
            }
            "getInputDevices" -> {
                result.success(getInputDeviceList())
            }
            else -> result.notImplemented()
        }
    }

    // ── Start ────────────────────────────────────────────────────────────────

    private fun startMonitoring(
        timeoutSeconds: Int,
        duckedFraction: Double,
        threshold: Int,
        mode: String,
        result: Result
    ) {
        if (isMonitoring) {
            result.error("ALREADY_RUNNING", "Monitoring is already active.", null)
            return
        }

        silenceTimeoutSeconds  = timeoutSeconds
        duckedVolumeFraction   = duckedFraction
        voiceThreshold         = threshold
        consecutiveVoicePolls  = 0
        detectionMode          = mode

        val serviceIntent = Intent(context, ConversationForegroundService::class.java)
            .apply { action = ConversationForegroundService.ACTION_START }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }

        bluetoothMicConnected = hasActiveBluetooth()
        wiredMicConnected     = hasActiveWiredHeadset()

        if (bluetoothMicConnected) {
            audioManager?.startBluetoothSco()
            audioManager?.isBluetoothScoOn = true
            // Pin AudioRecord to the BT SCO device.
            pinnedDevice = audioManager
                ?.getDevices(AudioManager.GET_DEVICES_INPUTS)
                ?.firstOrNull { it.type in BLUETOOTH_MIC_TYPES }
        } else if (wiredMicConnected && preferredMicMode == "auto") {
            // Pin AudioRecord to the wired headset mic right from the start.
            pinnedDevice = audioManager
                ?.getDevices(AudioManager.GET_DEVICES_INPUTS)
                ?.firstOrNull { it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET }
            // Force headset mic routing via audio mode.
            audioManager?.mode = AudioManager.MODE_IN_COMMUNICATION
        }

        audioManager?.registerAudioDeviceCallback(deviceCallback, mainHandler)

        Thread {
            // Load the NN model if needed (can take ~200 ms on first load).
            if (mode == "nn") {
                try {
                    loadVoiceDetector()
                } catch (e: Exception) {
                    mainHandler.post {
                        result.error("MODEL_ERROR",
                            "Failed to load YAMNet model: ${e.message}\n" +
                                    "Make sure yamnet.tflite is in android/app/src/main/assets/", null)
                    }
                    return@Thread
                }
            }

            try {
                initAudioRecord()
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("RECORDER_ERROR",
                        "Failed to start AudioRecord: ${e.message}", null)
                }
                return@Thread
            }

            isMonitoring        = true
            isVoiceActive       = false
            isInCountdown       = false
            silenceStartTime    = 0L
            lastCountdownSecond = -1
            lastMeterSendTime   = 0L
            nnRingWritePos      = 0
            nnRingFilled        = false

            recordingThread = Thread { recordingLoop() }.also { it.start() }

            mainHandler.post {
                val srcLabel = when {
                    bluetoothMicConnected -> "bluetooth"
                    wiredMicConnected     -> "wired"
                    else                  -> "builtin"
                }
                notifyFlutter("onMicSource",   srcLabel)
                notifyFlutter("onMicMode",     preferredMicMode)
                notifyFlutter("onDetectionMode", detectionMode)
                result.success(null)
            }
        }.start()
    }

    // ── Stop ─────────────────────────────────────────────────────────────────

    private fun stopMonitoring() {
        if (!isMonitoring) return
        isMonitoring = false

        audioManager?.unregisterAudioDeviceCallback(deviceCallback)
        audioManager?.stopBluetoothSco()
        audioManager?.isBluetoothScoOn = false

        recordingThread?.join(1000)
        recordingThread = null

        releaseAudioRecord()
        restoreVolume()
        voiceDetector?.close()
        voiceDetector = null

        val serviceIntent = Intent(context, ConversationForegroundService::class.java)
            .apply { action = ConversationForegroundService.ACTION_STOP }
        context.startService(serviceIntent)

        isVoiceActive         = false
        isInCountdown         = false
        silenceStartTime      = 0L
        lastCountdownSecond   = -1
        bluetoothMicConnected = false
        consecutiveVoicePolls = 0
        pinnedDevice          = null
        preferredMicMode      = "auto"
        wiredMicConnected     = false
        detectionMode         = "rms"
        abandonAudioFocus()
        originalVolume        = -1
        nnRingWritePos        = 0
        nnRingFilled          = false
        // Restore normal audio mode in case wired headset routing set
        // MODE_IN_COMMUNICATION.
        audioManager?.mode    = AudioManager.MODE_NORMAL
    }

    // ── Live detection mode switch ────────────────────────────────────────────

    private fun setDetectionMode(mode: String, result: Result) {
        if (mode == "nn" && voiceDetector == null) {
            try {
                loadVoiceDetector()
                voiceDetector?.speechThreshold =
                    VoiceDetector.sensitivityToThreshold(nnSensitivity)
            } catch (e: Exception) {
                result.error("MODEL_ERROR",
                    "Failed to load YAMNet model: ${e.message}\n" +
                            "Make sure yamnet.tflite is in android/app/src/main/assets/", null)
                return
            }
        }
        // Reset voice state so a stale counter doesn't carry across modes.
        consecutiveVoicePolls = 0
        nnRingWritePos = 0
        nnRingFilled   = false
        detectionMode  = mode
        notifyFlutter("onDetectionMode", mode)
        result.success(null)
    }

    private fun loadVoiceDetector() {
        if (voiceDetector?.isLoaded == true) return
        voiceDetector = VoiceDetector(context).also { it.load() }
    }

    // ── Mic mode ──────────────────────────────────────────────────────────────

    private fun setMicMode(mode: String, result: Result) {
        preferredMicMode = mode
        when (mode) {
            "bluetooth" -> {
                if (!bluetoothMicConnected) {
                    result.error("NO_BT_MIC", "No Bluetooth mic connected.", null)
                    return
                }
                rerouteAudioRecord(toBlue = true)
            }
            "builtin" -> rerouteAudioRecord(toBlue = false)
            "auto"    -> rerouteAudioRecord(toBlue = bluetoothMicConnected)
        }
        notifyFlutter("onMicMode", mode)
        result.success(null)
    }

    // ── AudioRecord ──────────────────────────────────────────────────────────

    private fun initAudioRecord(preferredDevice: AudioDeviceInfo? = pinnedDevice) {
        val minBuffer  = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        val bufferSize = maxOf(minBuffer, 4096)

        val recorder = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, bufferSize
        )

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            throw Exception("AudioRecord failed to initialize")
        }

        if (preferredDevice != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            recorder.setPreferredDevice(preferredDevice)
        }

        recorder.startRecording()
        audioRecord = recorder
    }

    private fun releaseAudioRecord() {
        try { audioRecord?.stop()    } catch (_: Exception) {}
        try { audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null
    }

    private fun rerouteAudioRecord(toBlue: Boolean) {
        if (!isMonitoring) return
        val old = audioRecord
        audioRecord = null
        consecutiveVoicePolls = 0
        nnRingWritePos = 0
        nnRingFilled   = false

        try { old?.stop()    } catch (_: Exception) {}
        try { old?.release() } catch (_: Exception) {}

        if (toBlue) {
            audioManager?.startBluetoothSco()
            audioManager?.isBluetoothScoOn = true
            pinnedDevice = audioManager
                ?.getDevices(AudioManager.GET_DEVICES_INPUTS)
                ?.firstOrNull { it.type in BLUETOOTH_MIC_TYPES }
        } else {
            audioManager?.stopBluetoothSco()
            audioManager?.isBluetoothScoOn = false
            pinnedDevice = if (preferredMicMode == "builtin") {
                audioManager?.getDevices(AudioManager.GET_DEVICES_INPUTS)
                    ?.firstOrNull { it.type in BUILTIN_MIC_TYPES }
            } else null
        }

        Thread.sleep(300L)

        try {
            initAudioRecord()
            notifyFlutter("onMicSource", if (toBlue) "bluetooth" else "builtin")
        } catch (e: Exception) {
            mainHandler.post {
                stopMonitoring()
                notifyFlutter("onMicError", "Mic re-route failed: ${e.message}")
            }
        }
    }

    /** Route AudioRecord to the wired headset mic. */
    private fun rerouteToWired() {
        if (!isMonitoring) return
        val old = audioRecord
        audioRecord = null
        consecutiveVoicePolls = 0
        nnRingWritePos = 0
        nnRingFilled   = false

        try { old?.stop()    } catch (_: Exception) {}
        try { old?.release() } catch (_: Exception) {}

        // Stop BT SCO — wired takes over.
        audioManager?.stopBluetoothSco()
        audioManager?.isBluetoothScoOn = false

        pinnedDevice = audioManager
            ?.getDevices(AudioManager.GET_DEVICES_INPUTS)
            ?.firstOrNull { it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET }

        // Setting MODE_IN_COMMUNICATION tells the OS audio policy to prefer
        // the headset mic over the built-in mic for AudioSource.MIC captures.
        audioManager?.mode = AudioManager.MODE_IN_COMMUNICATION

        Thread.sleep(200L)

        try {
            initAudioRecord()
            notifyFlutter("onMicSource", "wired")
        } catch (e: Exception) {
            mainHandler.post {
                stopMonitoring()
                notifyFlutter("onMicError", "Wired mic re-route failed: ${e.message}")
            }
        }
    }

    private fun hasActiveBluetooth(): Boolean {
        val am = audioManager ?: return false
        return am.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .any { it.type in BLUETOOTH_MIC_TYPES }
    }

    private fun hasActiveWiredHeadset(): Boolean {
        val am = audioManager ?: return false
        return am.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .any { it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET }
    }

    private fun getInputDeviceList(): List<Map<String, Any>> {
        val am = audioManager ?: return emptyList()
        return am.getDevices(AudioManager.GET_DEVICES_INPUTS).map { d ->
            mapOf(
                "id"          to d.id,
                "name"        to (d.productName?.toString() ?: "Unknown"),
                "type"        to d.type,
                "isBluetooth" to (d.type in BLUETOOTH_MIC_TYPES),
                "isBuiltin"   to (d.type in BUILTIN_MIC_TYPES),
            )
        }
    }

    // ── Recording loop ────────────────────────────────────────────────────────

    private fun recordingLoop() {
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        val buffer    = ShortArray(minBuffer)

        while (isMonitoring) {
            val record = audioRecord
            if (record == null) { Thread.sleep(20L); continue }

            val read = record.read(buffer, 0, buffer.size)
            if (read <= 0) continue

            val rms = calculateRMS(buffer, read).toInt()
            sendMeterReading(rms)

            when (detectionMode) {
                "nn"  -> processWithNN(buffer, read)
                else  -> processAmplitudeRMS(rms)
            }
        }
    }

    private fun calculateRMS(buffer: ShortArray, readSize: Int): Double {
        var sum = 0.0
        for (i in 0 until readSize) sum += buffer[i] * buffer[i].toDouble()
        return sqrt(sum / readSize)
    }

    // ── NN mode processing ────────────────────────────────────────────────────
    // Samples are written into a ring buffer. Once 975 ms of audio has
    // accumulated, we run YAMNet inference and treat the result as a boolean
    // voice/no-voice signal, then feed that into the existing state machine.

    private fun processWithNN(buffer: ShortArray, read: Int) {
        val detector = voiceDetector ?: run {
            // Fallback if model somehow unloaded
            processAmplitudeRMS(calculateRMS(buffer, read).toInt())
            return
        }

        // Write new samples into the ring buffer.
        for (i in 0 until read) {
            nnRingBuffer[nnRingWritePos] = buffer[i]
            nnRingWritePos = (nnRingWritePos + 1) % VoiceDetector.INPUT_SAMPLES
            if (nnRingWritePos == 0) nnRingFilled = true
        }

        // Don't run inference until we have a full window of audio.
        if (!nnRingFilled) return

        // Build a contiguous array starting from the oldest sample.
        val window = ShortArray(VoiceDetector.INPUT_SAMPLES)
        val tail = VoiceDetector.INPUT_SAMPLES - nnRingWritePos
        System.arraycopy(nnRingBuffer, nnRingWritePos, window, 0, tail)
        System.arraycopy(nnRingBuffer, 0, window, tail, nnRingWritePos)

        // Run inference (typically 20–60 ms on CPU, ~5 ms on GPU).
        val isSpeech = detector.isSpeech(window)

        // Feed the binary result into the same state machine as RMS mode.
        // We skip the consecutive-poll counter because YAMNet already
        // operates over a 975 ms window — that's inherent temporal smoothing.
        if (isSpeech) {
            silenceStartTime    = 0L
            lastCountdownSecond = -1
            if (!isVoiceActive || isInCountdown) {
                isVoiceActive = true
                isInCountdown = false
                duckVolume()
                notifyFlutter("onVoiceDetected", null)
            }
        } else {
            processSilence()
        }
    }

    // ── RMS mode processing ───────────────────────────────────────────────────

    private fun processAmplitudeRMS(amplitude: Int) {
        if (amplitude > voiceThreshold) {
            consecutiveVoicePolls++
            if (consecutiveVoicePolls >= VOICE_CONFIRM_POLLS) {
                silenceStartTime    = 0L
                lastCountdownSecond = -1
                if (!isVoiceActive || isInCountdown) {
                    isVoiceActive = true
                    isInCountdown = false
                    duckVolume()
                    notifyFlutter("onVoiceDetected", null)
                }
            }
        } else {
            consecutiveVoicePolls = 0
            processSilence()
        }
    }

    // ── Shared silence handling ───────────────────────────────────────────────

    private fun processSilence() {
        if (!isVoiceActive) return

        if (silenceTimeoutSeconds == 0) {
            if (silenceStartTime == 0L) silenceStartTime = System.currentTimeMillis()
            if (System.currentTimeMillis() - silenceStartTime < 500L) return
            resetToListening()
            return
        }

        if (silenceStartTime == 0L) {
            silenceStartTime = System.currentTimeMillis()
            isInCountdown    = true
        }

        val elapsedSeconds = ((System.currentTimeMillis() - silenceStartTime) / 1000L).toInt()
        val remaining      = (silenceTimeoutSeconds - elapsedSeconds).coerceAtLeast(0)

        if (elapsedSeconds >= silenceTimeoutSeconds) {
            resetToListening()
        } else if (remaining != lastCountdownSecond) {
            lastCountdownSecond = remaining
            notifyFlutter("onSilenceCountdown", remaining)
        }
    }

    private fun resetToListening() {
        isVoiceActive         = false
        isInCountdown         = false
        silenceStartTime      = 0L
        lastCountdownSecond   = -1
        consecutiveVoicePolls = 0
        restoreVolume()
        notifyFlutter("onSilenceRestored", null)
    }

    // ── Live meter ────────────────────────────────────────────────────────────

    private fun sendMeterReading(rms: Int) {
        val now = System.currentTimeMillis()
        if (now - lastMeterSendTime < METER_INTERVAL_MS) return
        lastMeterSendTime = now
        notifyFlutter("onAmplitude", rms)
    }

    // ── Volume ────────────────────────────────────────────────────────────────

    private fun duckVolume() {
        if (pauseAudioEnabled) {
            // Request audio focus with AUDIOFOCUS_GAIN_TRANSIENT — this signals
            // to other apps (Spotify, YouTube, etc.) that they should pause
            // completely until we abandon focus.
            requestAudioFocus()
        } else {
            // Standard volume duck — reduce to the user-configured level.
            val am = audioManager ?: return
            if (originalVolume == -1) {
                originalVolume = am.getStreamVolume(AudioManager.STREAM_MUSIC)
            }
            val maxVol    = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val duckedVol = (maxVol * duckedVolumeFraction).toInt().coerceAtLeast(0)
            am.setStreamVolume(AudioManager.STREAM_MUSIC, duckedVol, 0)
        }
    }

    private fun restoreVolume() {
        if (pauseAudioEnabled) {
            abandonAudioFocus()
        } else {
            if (originalVolume == -1) return
            try { audioManager?.setStreamVolume(AudioManager.STREAM_MUSIC, originalVolume, 0) }
            catch (_: Exception) {}
            originalVolume = -1
        }
    }

    // ── Audio focus (pause mode) ──────────────────────────────────────────────

    private fun requestAudioFocus() {
        val am = audioManager ?: return
        if (hadAudioFocus) return   // already holding focus

        val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            // We don't want Android to duck us — we ARE the talker.
            .setWillPauseWhenDucked(false)
            .setAcceptsDelayedFocusGain(false)
            .setOnAudioFocusChangeListener { focusChange ->
                // If we unexpectedly lose focus, update our tracking flag.
                if (focusChange == AudioManager.AUDIOFOCUS_LOSS ||
                    focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                    hadAudioFocus = false
                }
            }
            .build()

        val result = am.requestAudioFocus(focusRequest)
        if (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            audioFocusRequest = focusRequest
            hadAudioFocus = true
        }
    }

    private fun abandonAudioFocus() {
        val req = audioFocusRequest ?: return
        audioManager?.abandonAudioFocusRequest(req)
        audioFocusRequest = null
        hadAudioFocus = false
    }

    // ── Flutter events ────────────────────────────────────────────────────────

    private fun notifyFlutter(method: String, argument: Any?) {
        mainHandler.post { channel.invokeMethod(method, argument) }
    }
}