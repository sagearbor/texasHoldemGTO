package com.sagearbor.feltnotes.pulse

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Pulse watch <-> phone protocol v1 (docs/PULSE.md). Pure Kotlin, no Android:
 * compiled into the Wear app (watch/wear/wearApp) AND the phone bridge
 * (android/app adds this directory as a source dir), and unit-tested against
 * test/pulse/protocol_vectors.json, the same file the Dart and Swift tests read.
 */
object PulseProtocol {
    const val VERSION = 1
    const val PATH_HR = "/feltnotes/pulse/v1/hr"
    const val PATH_CTL = "/feltnotes/pulse/v1/ctl"
    const val PATH_STATE = "/feltnotes/pulse/v1/state"

    /** Declared by the Wear app (res/values/wear.xml): "Felt Notes Pulse is installed". */
    const val CAPABILITY_WATCH = "feltnotes_pulse_watch"
    /** Declared by the phone app (android/app res/values/wear.xml). */
    const val CAPABILITY_PHONE = "feltnotes_pulse_phone"

    const val CMD_START = "start"
    const val CMD_STOP = "stop"

    /** One heart-rate sample: epoch ms on the watch clock, beats per minute. */
    data class Sample(val tMs: Long, val bpm: Int)

    sealed class Message {
        data class Hr(val samples: List<Sample>) : Message()
        data class State(val running: Boolean, val err: String?) : Message()
        data class Ctl(val cmd: String) : Message()
    }

    // ---- encode (exact bytes match the vectors) ----

    fun encodeHr(samples: List<Sample>): String =
        samples.joinToString(",", prefix = "{\"v\":1,\"s\":[", postfix = "]}") { "[${it.tMs},${it.bpm}]" }

    fun encodeState(running: Boolean, err: String?): String =
        "{\"v\":1,\"running\":$running,\"err\":${if (err == null) "null" else JsonPrimitive(err).toString()}}"

    fun encodeCtl(cmd: String): String {
        require(cmd == CMD_START || cmd == CMD_STOP) { "unknown cmd $cmd" }
        return "{\"v\":1,\"cmd\":\"$cmd\"}"
    }

    /** (path, UTF-8 JSON) for a message, ready for MessageClient.sendMessage. */
    fun encode(msg: Message): Pair<String, String> = when (msg) {
        is Message.Hr -> PATH_HR to encodeHr(msg.samples)
        is Message.State -> PATH_STATE to encodeState(msg.running, msg.err)
        is Message.Ctl -> PATH_CTL to encodeCtl(msg.cmd)
    }

    // ---- parse ----

    /** Parses one message; null for anything not valid v1 (unknown path or
     * version, bad JSON, wrong shapes, unknown cmd). Never throws. */
    fun parse(path: String, json: String): Message? {
        if (path != PATH_HR && path != PATH_CTL && path != PATH_STATE) return null
        val obj = try {
            Json.parseToJsonElement(json) as? JsonObject
        } catch (e: Exception) {
            null
        } ?: return null
        if ((obj["v"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull != VERSION) return null
        return when (path) {
            PATH_HR -> {
                val arr = obj["s"] as? JsonArray ?: return null
                val samples = ArrayList<Sample>(arr.size)
                for (el in arr) {
                    val pair = el as? JsonArray ?: return null
                    if (pair.size != 2) return null
                    val t = (pair[0] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: return null
                    val bpm = (pair[1] as? JsonPrimitive)?.takeIf { !it.isString }?.let { p ->
                        p.intOrNull ?: p.content.toDoubleOrNull()?.let { Math.round(it).toInt() }
                    } ?: return null
                    samples.add(Sample(t, bpm))
                }
                Message.Hr(samples)
            }
            PATH_STATE -> {
                val running = (obj["running"] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
                    ?: return null
                val errEl = obj["err"]
                val err = when {
                    errEl == null || errEl is JsonNull -> null
                    errEl is JsonPrimitive && errEl.isString -> errEl.content
                    else -> return null
                }
                Message.State(running, err)
            }
            else -> {
                val cmd = (obj["cmd"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                if (cmd == CMD_START || cmd == CMD_STOP) Message.Ctl(cmd) else null
            }
        }
    }

    /** The map sent to Dart on EventChannel("feltnotes/pulse/events"). */
    fun toChannelMap(msg: Message): Map<String, Any?> = when (msg) {
        is Message.Hr -> mapOf("type" to "hr", "s" to msg.samples.map { listOf(it.tMs, it.bpm) })
        is Message.State -> mapOf("type" to "state", "running" to msg.running, "err" to msg.err)
        is Message.Ctl -> mapOf("type" to "ctl", "cmd" to msg.cmd)
    }
}
