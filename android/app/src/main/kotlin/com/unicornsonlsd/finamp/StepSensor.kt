package com.unicornsonlsd.finamp

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.plugin.common.EventChannel

/** Sends the time of each step (milliseconds since boot) while running mode listens. */
class StepSensor(context: Context) : EventChannel.StreamHandler, SensorEventListener {
    private val sensors = context.getSystemService(SensorManager::class.java)
    private val detector: Sensor? = sensors?.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR)
    private var sink: EventChannel.EventSink? = null

    val available get() = detector != null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        detector?.let { sensors?.registerListener(this, it, SensorManager.SENSOR_DELAY_FASTEST) }
    }

    override fun onCancel(arguments: Any?) {
        sensors?.unregisterListener(this)
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        sink?.success(event.timestamp / 1_000_000L)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
