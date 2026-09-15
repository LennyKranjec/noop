package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The on-device coach catalogue: the two entries, their download URLs and the id round-trip.
 *
 * Pure data, so this runs in the plain-JVM suite. What it is actually guarding is the URL assembly
 * — the one place a typo silently becomes a 404 the user only meets after tapping Download, and the
 * one place a wrong repo would fetch a DIFFERENT model under the right label.
 */
class LocalModelTest {

    @Test
    fun fastIsTheDefaultAndIsNotExperimental() {
        assertEquals(LocalModel.FAST, LocalModel.default)
        assertFalse(LocalModel.FAST.experimental)
        assertTrue(LocalModel.DEEP.experimental)
    }

    @Test
    fun downloadUrlsPointAtTheVerifiedGgufFiles() {
        assertEquals(
            "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf",
            LocalModel.FAST.downloadUrl,
        )
        assertEquals(
            "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf",
            LocalModel.DEEP.downloadUrl,
        )
    }

    /** The on-disk name is the model ID, so renaming a repo upstream cannot orphan an installed file. */
    @Test
    fun fileNamesAreKeyedOnTheIdNotTheUpstreamFilename() {
        assertEquals("qwen35-0_8b-q4km.gguf", LocalModel.FAST.fileName)
        assertEquals("qwen35-2b-q4km.gguf", LocalModel.DEEP.fileName)
    }

    @Test
    fun idsRoundTripAndUnknownIdsAreRejected() {
        LocalModel.entries.forEach { assertEquals(it, LocalModel.fromId(it.id)) }
        assertNull(LocalModel.fromId("something-else"))
        assertNull(LocalModel.fromId(null))
    }

    @Test
    fun progressFractionIsBoundedAndSurvivesAZeroTotal() {
        assertEquals(0.5f, LocalModelStore.Progress(50, 100).fraction, 1e-6f)
        assertEquals(1f, LocalModelStore.Progress(500, 100).fraction, 1e-6f)
        assertEquals(0f, LocalModelStore.Progress(10, 0).fraction, 1e-6f)
    }
}
