package com.sagearbor.feltnotes.pulse

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Runs the shared vectors (test/pulse/protocol_vectors.json) that the Dart
 * parser test and the Apple Watch tests also run. */
class PulseProtocolTest {

    private val vectors: JsonObject by lazy {
        Json.parseToJsonElement(vectorsFile().readText()).jsonObject
    }

    private fun vectorsFile(): File {
        val rel = "test/pulse/protocol_vectors.json"
        System.getProperty("feltnotes.repoRoot")?.let { root ->
            File(root, rel).takeIf { it.isFile }?.let { return it }
        }
        // Fallback: walk up from the working directory (IDE runs).
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val f = File(dir, rel)
            if (f.isFile) return f
            dir = dir.parentFile
        }
        error("cannot find $rel above ${System.getProperty("user.dir")}")
    }

    /** JSON -> plain Kotlin values with all numbers as Long, for comparing. */
    private fun plain(e: JsonElement): Any? = when (e) {
        is JsonNull -> null
        is JsonObject -> e.mapValues { plain(it.value) }
        is JsonArray -> e.map { plain(it) }
        is JsonPrimitive -> when {
            e.isString -> e.content
            e.booleanOrNull != null -> e.booleanOrNull
            else -> e.longOrNull ?: e.content.toDouble()
        }
    }

    private fun normalize(v: Any?): Any? = when (v) {
        is Map<*, *> -> v.entries.associate { it.key to normalize(it.value) }
        is List<*> -> v.map { normalize(it) }
        is Int -> v.toLong()
        else -> v
    }

    @Test
    fun validVectorsParseToExpectedMaps() {
        val valid = vectors["valid"]!!.jsonArray
        assertTrue(valid.size >= 6)
        for (vec in valid) {
            val o = vec.jsonObject
            val path = o["path"]!!.jsonPrimitive.content
            val json = o["json"]!!.jsonPrimitive.content
            val msg = PulseProtocol.parse(path, json)
            assertNotNull("should parse: $path $json", msg)
            assertEquals("map for $json", plain(o["expect"]!!), normalize(PulseProtocol.toChannelMap(msg!!)))
        }
    }

    @Test
    fun validVectorsEncodeToTheExactSameBytes() {
        for (vec in vectors["valid"]!!.jsonArray) {
            val o = vec.jsonObject
            val path = o["path"]!!.jsonPrimitive.content
            val json = o["json"]!!.jsonPrimitive.content
            val msg = PulseProtocol.parse(path, json)!!
            assertEquals(path to json, PulseProtocol.encode(msg))
        }
    }

    @Test
    fun invalidVectorsAreRejected() {
        val invalid = vectors["invalid"]!!.jsonArray
        assertTrue(invalid.isNotEmpty())
        for (vec in invalid) {
            val o = vec.jsonObject
            val path = o["path"]!!.jsonPrimitive.content
            val json = o["json"]!!.jsonPrimitive.content
            assertNull("should reject (${o["why"]}): $path $json", PulseProtocol.parse(path, json))
        }
    }

    @Test
    fun malformedShapesAreRejectedNotThrown() {
        val hr = PulseProtocol.PATH_HR
        assertNull(PulseProtocol.parse(hr, "[]"))
        assertNull(PulseProtocol.parse(hr, "{\"v\":1}"))
        assertNull(PulseProtocol.parse(hr, "{\"v\":1,\"s\":[[1,2,3]]}"))
        assertNull(PulseProtocol.parse(hr, "{\"v\":1,\"s\":[[\"1\",72]]}"))
        assertNull(PulseProtocol.parse(hr, "{\"v\":\"1\",\"s\":[]}"))
        assertNull(PulseProtocol.parse(PulseProtocol.PATH_STATE, "{\"v\":1,\"running\":\"yes\",\"err\":null}"))
        assertNull(PulseProtocol.parse(PulseProtocol.PATH_STATE, "{\"v\":1,\"running\":true,\"err\":5}"))
        assertNull(PulseProtocol.parse(PulseProtocol.PATH_CTL, "{\"v\":1}"))
    }

    @Test
    fun stateErrIsEscaped() {
        val json = PulseProtocol.encodeState(false, "a\"b")
        val back = PulseProtocol.parse(PulseProtocol.PATH_STATE, json)
        assertEquals(PulseProtocol.Message.State(false, "a\"b"), back)
    }
}
