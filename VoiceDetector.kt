package com.device_tools.conversation_awareness

import android.content.Context
import com.google.mediapipe.tasks.audio.audioclassifier.AudioClassifier
import com.google.mediapipe.tasks.audio.core.RunningMode
import com.google.mediapipe.tasks.components.containers.AudioData
import com.google.mediapipe.tasks.components.containers.AudioData.AudioDataFormat
import com.google.mediapipe.tasks.core.BaseOptions

/**
 * Wraps the YAMNet TFLite model using the MediaPipe Tasks Audio API.
 *
 * YAMNet speech classes (AudioSet ontology indices):
 *   0  Speech
 *   1  Male speech, man speaking
 *   2  Female speech, woman speaking
 *   3  Child speech, kid speaking
 *
 * We sum those four scores. A combined score ≥ SPEECH_THRESHOLD
 * is treated as voice detected.
 */
class VoiceDetector(private val context: Context) {

    companion object {
        private const val MODEL_FILE     = "yamnet.tflite"
        private val SPEECH_CLASS_INDICES = intArrayOf(0, 1, 2, 3)

        // YAMNet fixed input: 975 ms × 16 000 Hz = 15 600 samples, mono.
        const val INPUT_SAMPLES = 15600
        const val SAMPLE_RATE   = 16000

        // Sensitivity → threshold mapping.
        // sensitivity is a Float in [0, 1] where 1 = most sensitive.
        // We map it to a score threshold in [0.10, 0.80] (inverted).
        private const val THRESHOLD_MIN = 0.10f   // sensitivity = 1.0 (most sensitive)
        private const val THRESHOLD_MAX = 0.80f   // sensitivity = 0.0 (least sensitive)
        private const val DEFAULT_SENSITIVITY = 0.50f  // → threshold ≈ 0.45

        fun sensitivityToThreshold(sensitivity: Float): Float {
            val clamped = sensitivity.coerceIn(0f, 1f)
            // Higher sensitivity → lower threshold (triggers more easily).
            return THRESHOLD_MAX - clamped * (THRESHOLD_MAX - THRESHOLD_MIN)
        }
    }

    // Mutable at runtime so Flutter can update it live without reloading the model.
    var speechThreshold: Float = sensitivityToThreshold(DEFAULT_SENSITIVITY)

    private var classifier: AudioClassifier? = null

    val isLoaded get() = classifier != null

    /** Load the model from assets. Safe to call multiple times. */
    fun load() {
        if (classifier != null) return

        // CPU is the default delegate — no need to set it explicitly.
        // BaseOptions only needs the model path.
        val baseOptions = BaseOptions.builder()
            .setModelAssetPath(MODEL_FILE)
            .build()

        // AudioClassifierOptions is a nested abstract class inside AudioClassifier.
        val options = AudioClassifier.AudioClassifierOptions.builder()
            .setBaseOptions(baseOptions)
            .setRunningMode(RunningMode.AUDIO_CLIPS)
            .setMaxResults(10)
            .build()

        try {
            classifier = AudioClassifier.createFromOptions(context, options)
        } catch (e: Exception) {
            classifier = null
            throw RuntimeException(
                "Failed to load YAMNet — make sure yamnet.tflite is in " +
                        "android/app/src/main/assets/: ${e.message}", e
            )
        }
    }

    /** Release classifier resources. */
    fun close() {
        classifier?.close()
        classifier = null
    }

    /**
     * Run inference on [samples] (raw PCM int16 from AudioRecord).
     * Returns true when the combined speech score meets SPEECH_THRESHOLD.
     */
    fun isSpeech(samples: ShortArray, offset: Int = 0): Boolean =
        speechScore(samples, offset) >= speechThreshold

    /**
     * Returns the raw combined speech score (sum of 4 probabilities, 0–~4).
     */
    fun speechScore(samples: ShortArray, offset: Int = 0): Float {
        val cls = classifier ?: return 0f
        if (samples.size - offset < INPUT_SAMPLES) return 0f

        // Convert int16 PCM → float32 normalised to [-1, 1].
        val floats = FloatArray(INPUT_SAMPLES) { i ->
            samples[offset + i] / 32768.0f
        }

        // Build AudioDataFormat using the builder (not AudioDataFormat.builder()
        // with setNumOfChannels — the correct method is numOfChannels()).
        val format = AudioDataFormat.builder()
            .setNumOfChannels(1)
            .setSampleRate(SAMPLE_RATE.toFloat())
            .build()

        val audioData = AudioData.create(format, INPUT_SAMPLES)
        audioData.load(floats, 0, INPUT_SAMPLES)

        val results = cls.classify(audioData)
        if (results.classificationResults().isEmpty()) return 0f

        val classifications = results.classificationResults()[0].classifications()
        if (classifications.isEmpty()) return 0f

        // Build index → score map from returned categories.
        val scoreMap = mutableMapOf<Int, Float>()
        for (category in classifications[0].categories()) {
            scoreMap[category.index()] = category.score()
        }

        return SPEECH_CLASS_INDICES.sumOf { idx ->
            (scoreMap[idx] ?: 0f).toDouble()
        }.toFloat()
    }
}