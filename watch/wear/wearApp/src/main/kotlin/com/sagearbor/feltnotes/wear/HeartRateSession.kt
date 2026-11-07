package com.sagearbor.feltnotes.wear

import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.health.services.client.ExerciseUpdateCallback
import androidx.health.services.client.HealthServices
import androidx.health.services.client.MeasureCallback
import androidx.health.services.client.data.Availability
import androidx.health.services.client.data.BatchingMode
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.DeltaDataType
import androidx.health.services.client.data.ExerciseConfig
import androidx.health.services.client.data.ExerciseLapSummary
import androidx.health.services.client.data.ExerciseTrackedStatus
import androidx.health.services.client.data.ExerciseType
import androidx.health.services.client.data.ExerciseUpdate
import androidx.health.services.client.data.SampleDataPoint
import com.sagearbor.feltnotes.pulse.PulseProtocol.Sample
import kotlinx.coroutines.guava.await
import java.time.Instant

/**
 * Heart rate from Health Services.
 *
 * v1 (shipping): MeasureClient only. It delivers about once a second while
 * the app's activity is on screen (kept on, dimming to ambient), and stops
 * by itself if the app dies, so no workout can be left running.
 *
 * Later ([USE_EXERCISE] = true, together with restoring the "health"
 * foreground service from commit 6d9cc73): an ExerciseClient exercise keeps
 * sampling with the screen off. That needs Play's FOREGROUND_SERVICE_HEALTH
 * declaration (demo video), which is why it is off. With it on, if another
 * app already owns an exercise we fall back to MeasureClient.
 *
 * Callbacks run on the main thread.
 */
class HeartRateSession(
    context: Context,
    private val onSample: (Sample) -> Unit,
    /** Health Services ended the exercise on its own (not via [stop]). */
    private val onLost: () -> Unit,
) {
    private val ctx = context.applicationContext
    private val hs = HealthServices.getClient(ctx)
    private val main = ContextCompat.getMainExecutor(ctx)
    private enum class Mode { NONE, EXERCISE, MEASURE }
    private var mode = Mode.NONE
    private var stopping = false

    private fun bootInstant(): Instant =
        Instant.ofEpochMilli(System.currentTimeMillis() - SystemClock.elapsedRealtime())

    private fun deliver(points: List<SampleDataPoint<Double>>) {
        val boot = bootInstant()
        for (p in points) {
            val bpm = Math.round(p.value).toInt()
            if (bpm <= 0) continue
            onSample(Sample(p.getTimeInstant(boot).toEpochMilli(), bpm))
        }
    }

    private val exerciseCallback = object : ExerciseUpdateCallback {
        override fun onExerciseUpdateReceived(update: ExerciseUpdate) {
            deliver(update.latestMetrics.getData(DataType.HEART_RATE_BPM))
            if (update.exerciseStateInfo.state.isEnded && !stopping && mode == Mode.EXERCISE) {
                Log.i(TAG, "exercise ended by system: ${update.exerciseStateInfo.endReason}")
                mode = Mode.NONE
                onLost()
            }
        }
        override fun onLapSummaryReceived(lapSummary: ExerciseLapSummary) = Unit
        override fun onRegistered() = Unit
        override fun onRegistrationFailed(throwable: Throwable) {
            Log.w(TAG, "exercise callback registration failed: $throwable")
        }
        override fun onAvailabilityChanged(dataType: DataType<*, *>, availability: Availability) = Unit
    }

    private val measureCallback = object : MeasureCallback {
        override fun onAvailabilityChanged(dataType: DeltaDataType<*, *>, availability: Availability) = Unit
        override fun onDataReceived(data: DataPointContainer) {
            deliver(data.getData(DataType.HEART_RATE_BPM))
        }
    }

    /** Starts sampling; returns null on success or a [PulseErr] code. */
    suspend fun start(): String? {
        stopping = false
        return try {
            if (USE_EXERCISE && tryExercise()) null else tryMeasure()
        } catch (e: Exception) {
            Log.w(TAG, "start failed: $e")
            mode = Mode.NONE
            if (e is SecurityException) PulseErr.NO_PERMISSION else PulseErr.SENSOR_ERROR
        }
    }

    private suspend fun tryExercise(): Boolean {
        val client = hs.exerciseClient
        val type = ExerciseType.WORKOUT
        val caps = client.getCapabilitiesAsync().await()
        if (type !in caps.supportedExerciseTypes) return false
        val typeCaps = caps.getExerciseTypeCapabilities(type)
        if (DataType.HEART_RATE_BPM !in typeCaps.supportedDataTypes) return false
        val info = client.getCurrentExerciseInfoAsync().await()
        if (info.exerciseTrackedStatus == ExerciseTrackedStatus.OTHER_APP_IN_PROGRESS) {
            Log.i(TAG, "another app's exercise is running; using MeasureClient")
            return false
        }
        val builder = ExerciseConfig.builder(type)
            .setDataTypes(setOf(DataType.HEART_RATE_BPM))
            .setIsAutoPauseAndResumeEnabled(false)
            .setIsGpsEnabled(false)
        if (BatchingMode.HEART_RATE_5_SECONDS in caps.supportedBatchingModeOverrides) {
            builder.setBatchingModeOverrides(setOf(BatchingMode.HEART_RATE_5_SECONDS))
        }
        client.setUpdateCallback(main, exerciseCallback)
        client.startExerciseAsync(builder.build()).await()
        mode = Mode.EXERCISE
        return true
    }

    private suspend fun tryMeasure(): String? {
        val client = hs.measureClient
        val caps = client.getCapabilitiesAsync().await()
        if (DataType.HEART_RATE_BPM !in caps.supportedDataTypesMeasure) return PulseErr.UNSUPPORTED
        client.registerMeasureCallback(DataType.HEART_RATE_BPM, main, measureCallback)
        mode = Mode.MEASURE
        return null
    }

    suspend fun stop() {
        stopping = true
        val was = mode
        mode = Mode.NONE
        try {
            when (was) {
                Mode.EXERCISE -> {
                    hs.exerciseClient.endExerciseAsync().await()
                    hs.exerciseClient.clearUpdateCallbackAsync(exerciseCallback).await()
                }
                Mode.MEASURE ->
                    hs.measureClient.unregisterMeasureCallbackAsync(DataType.HEART_RATE_BPM, measureCallback).await()
                Mode.NONE -> Unit
            }
        } catch (e: Exception) {
            Log.w(TAG, "stop: $e")
        }
    }

    companion object {
        private const val TAG = "FeltPulse"
        /** Off in v1: see the class comment (needs the foreground service). */
        const val USE_EXERCISE = false
    }
}
