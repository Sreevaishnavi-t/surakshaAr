package org.suraksha.surakshaar

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.util.SizeF
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.atan

/**
 * Bridges Android device pose and camera intrinsics to Dart.
 *
 * Pose deliberately prefers TYPE_GAME_ROTATION_VECTOR over TYPE_ROTATION_VECTOR.
 * Game rotation vector fuses gyroscope + accelerometer and *excludes the
 * magnetometer*. That matters enormously here: the target environments are
 * underground coal galleries and steel plants, where ferrous mass and motor
 * fields make magnetic heading unusable. We give up absolute north (which we
 * never need — the scene is origined on a marker or a calibration gesture) and
 * in exchange get orientation that stays stable next to a running conveyor.
 *
 * Fallback order:
 *   1. GAME_ROTATION_VECTOR  — preferred, no magnetometer
 *   2. ROTATION_VECTOR       — uses magnetometer, acceptable above ground
 *   3. none                  — Dart falls back to the Madgwick AHRS filter
 */
class PoseChannel(
    private val context: Context,
) : EventChannel.StreamHandler, MethodChannel.MethodCallHandler, SensorEventListener {

    companion object {
        private const val EVENT_CHANNEL = "org.suraksha.surakshaar/pose"
        private const val METHOD_CHANNEL = "org.suraksha.surakshaar/pose_meta"

        /**
         * Raw accelerometer + gyroscope, for the Dart-side Madgwick fallback.
         *
         * Only subscribed when neither fused rotation sensor exists, so on the
         * overwhelming majority of handsets this channel never opens and costs
         * nothing.
         */
        private const val IMU_CHANNEL = "org.suraksha.surakshaar/imu"

        const val SOURCE_NONE = 0
        const val SOURCE_GAME_ROTATION_VECTOR = 1
        const val SOURCE_ROTATION_VECTOR = 2

        /** Sampling period in microseconds. ~100 Hz — comfortably above the 60 Hz render rate. */
        private const val SAMPLING_PERIOD_US = 10_000
    }

    private var eventChannel: EventChannel? = null
    private var methodChannel: MethodChannel? = null
    private var imuChannel: EventChannel? = null
    private var sink: EventChannel.EventSink? = null

    private val imuHandler = ImuStreamHandler(sensorManagerProvider = { sensorManager })

    private val sensorManager: SensorManager? =
        context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager

    private var activeSensor: Sensor? = null
    private var activeSource: Int = SOURCE_NONE

    /** Reused across events so the hot path allocates nothing but the emitted list. */
    private val quaternion = FloatArray(4)

    fun attach(messenger: BinaryMessenger) {
        eventChannel = EventChannel(messenger, EVENT_CHANNEL).also { it.setStreamHandler(this) }
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).also { it.setMethodCallHandler(this) }
        imuChannel = EventChannel(messenger, IMU_CHANNEL).also { it.setStreamHandler(imuHandler) }
    }

    fun detach() {
        stopListening()
        imuHandler.onCancel(null)
        eventChannel?.setStreamHandler(null)
        methodChannel?.setMethodCallHandler(null)
        imuChannel?.setStreamHandler(null)
        eventChannel = null
        methodChannel = null
        imuChannel = null
    }

    // ---------------------------------------------------------------- pose stream

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val manager = sensorManager
        if (manager == null) {
            activeSource = SOURCE_NONE
            return
        }

        val game = manager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
        val absolute = manager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)

        val chosen = game ?: absolute
        activeSource = when {
            game != null -> SOURCE_GAME_ROTATION_VECTOR
            absolute != null -> SOURCE_ROTATION_VECTOR
            else -> SOURCE_NONE
        }

        if (chosen == null) return

        activeSensor = chosen
        manager.registerListener(this, chosen, SAMPLING_PERIOD_US)
    }

    override fun onCancel(arguments: Any?) {
        stopListening()
        sink = null
    }

    private fun stopListening() {
        activeSensor?.let { sensorManager?.unregisterListener(this, it) }
        activeSensor = null
    }

    override fun onSensorChanged(event: SensorEvent?) {
        val e = event ?: return
        val out = sink ?: return
        if (e.sensor.type != Sensor.TYPE_GAME_ROTATION_VECTOR &&
            e.sensor.type != Sensor.TYPE_ROTATION_VECTOR
        ) {
            return
        }

        // Yields [w, x, y, z] in the Android world frame (device -> world).
        SensorManager.getQuaternionFromVector(quaternion, e.values)

        out.success(
            listOf(
                quaternion[0].toDouble(), // w
                quaternion[1].toDouble(), // x
                quaternion[2].toDouble(), // y
                quaternion[3].toDouble(), // z
                activeSource.toDouble(),
                displayRotationDegrees().toDouble(),
                e.timestamp.toDouble(), // nanoseconds, monotonic
            ),
        )
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    /**
     * Rotation of the display relative to the device's natural orientation. Dart
     * needs this to remap sensor axes: "natural" is portrait on phones but
     * landscape on some tablets, and getting it wrong tilts the whole scene 90°.
     */
    private fun displayRotationDegrees(): Int {
        val rotation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            context.display?.rotation
        } else {
            @Suppress("DEPRECATION")
            (context.getSystemService(Context.WINDOW_SERVICE) as? android.view.WindowManager)
                ?.defaultDisplay?.rotation
        }
        return when (rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
    }

    // ------------------------------------------------------------- camera intrinsics

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(capabilities())
            "cameraIntrinsics" -> result.success(cameraIntrinsics())
            else -> result.notImplemented()
        }
    }

    private fun capabilities(): Map<String, Any> {
        val manager = sensorManager
        return mapOf(
            "hasGameRotationVector" to
                (manager?.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR) != null),
            "hasRotationVector" to
                (manager?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) != null),
            "hasGyroscope" to (manager?.getDefaultSensor(Sensor.TYPE_GYROSCOPE) != null),
            "hasAccelerometer" to (manager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) != null),
            "hasMagnetometer" to (manager?.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD) != null),
        )
    }

    /**
     * True field of view of the rear camera, derived from Camera2 metadata.
     *
     * This is not cosmetic. If the virtual camera's FOV disagrees with the real
     * lens, overlays visibly slide against the world as the worker turns — the
     * single most damaging artefact in markerless AR. Assuming a generic 60°
     * can be off by 15° or more on wide-angle budget sensors.
     *
     * We return the raw sensor geometry as well as the derived angles so Dart can
     * recompute FOV for whatever preview aspect ratio the camera actually delivers,
     * since the active crop is usually narrower than the full sensor.
     */
    private fun cameraIntrinsics(): Map<String, Any>? {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager ?: return null
        return try {
            for (id in manager.cameraIdList) {
                val ch = manager.getCameraCharacteristics(id)
                if (ch.get(CameraCharacteristics.LENS_FACING) != CameraCharacteristics.LENS_FACING_BACK) {
                    continue
                }
                val focal = ch.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                    ?.firstOrNull() ?: continue
                val physical: SizeF = ch.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: continue
                if (focal <= 0f || physical.width <= 0f || physical.height <= 0f) continue

                return mapOf(
                    "cameraId" to id,
                    "focalLengthMm" to focal.toDouble(),
                    "sensorWidthMm" to physical.width.toDouble(),
                    "sensorHeightMm" to physical.height.toDouble(),
                    "horizontalFovRad" to (2.0 * atan((physical.width / 2.0) / focal)),
                    "verticalFovRad" to (2.0 * atan((physical.height / 2.0) / focal)),
                )
            }
            null
        } catch (t: Throwable) {
            // Some OEM builds throw on camera enumeration before permission is granted.
            // Dart treats null as "use the default FOV plus the calibration slider".
            null
        }
    }
}

/**
 * Streams raw accelerometer and gyroscope samples.
 *
 * Feeds the Dart-side Madgwick filter on the small number of devices that
 * expose neither GAME_ROTATION_VECTOR nor ROTATION_VECTOR. Samples are emitted
 * on each gyroscope event, carrying the most recent accelerometer reading, so
 * Dart receives one coherent packet per integration step rather than having to
 * pair two independent streams.
 *
 * If the device has no gyroscope at all, accelerometer events drive the stream
 * with zero rates. That yields tilt without heading — enough to keep the
 * horizon level, which is a good deal better than a frozen scene.
 */
class ImuStreamHandler(
    private val sensorManagerProvider: () -> SensorManager?,
) : EventChannel.StreamHandler, SensorEventListener {

    private var sink: EventChannel.EventSink? = null
    private var accelerometer: Sensor? = null
    private var gyroscope: Sensor? = null

    private val latestAcceleration = FloatArray(3)
    private var hasAcceleration = false

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val manager = sensorManagerProvider() ?: return

        accelerometer = manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        gyroscope = manager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)

        accelerometer?.let { manager.registerListener(this, it, 10_000) }
        gyroscope?.let { manager.registerListener(this, it, 10_000) }
    }

    override fun onCancel(arguments: Any?) {
        sensorManagerProvider()?.unregisterListener(this)
        accelerometer = null
        gyroscope = null
        hasAcceleration = false
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent?) {
        val e = event ?: return
        val out = sink ?: return

        when (e.sensor.type) {
            Sensor.TYPE_ACCELEROMETER -> {
                latestAcceleration[0] = e.values[0]
                latestAcceleration[1] = e.values[1]
                latestAcceleration[2] = e.values[2]
                hasAcceleration = true

                // Only drive the stream from the accelerometer when there is no
                // gyroscope; otherwise the gyroscope sets the pace.
                if (gyroscope == null) {
                    emit(out, 0f, 0f, 0f, e.timestamp)
                }
            }

            Sensor.TYPE_GYROSCOPE -> {
                if (!hasAcceleration) return
                emit(out, e.values[0], e.values[1], e.values[2], e.timestamp)
            }
        }
    }

    private fun emit(
        out: EventChannel.EventSink,
        gx: Float,
        gy: Float,
        gz: Float,
        timestampNs: Long,
    ) {
        out.success(
            listOf(
                latestAcceleration[0].toDouble(),
                latestAcceleration[1].toDouble(),
                latestAcceleration[2].toDouble(),
                gx.toDouble(),
                gy.toDouble(),
                gz.toDouble(),
                timestampNs.toDouble(),
            ),
        )
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
}

/** Thin FlutterPlugin wrapper so the channel is registered with the engine lifecycle. */
class PosePlugin : FlutterPlugin {
    private var channel: PoseChannel? = null
    private var exitReasons: ExitReasonChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = PoseChannel(binding.applicationContext).also { it.attach(binding.binaryMessenger) }
        exitReasons = ExitReasonChannel(binding.applicationContext)
            .also { it.attach(binding.binaryMessenger) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.detach()
        channel = null
        exitReasons?.detach()
        exitReasons = null
    }
}
