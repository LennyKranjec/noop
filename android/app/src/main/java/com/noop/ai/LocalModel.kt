package com.noop.ai

// MARK: - The on-device coach models
//
// NOOP's coach has always been BYOK over HTTP: a key, a provider and a request that leaves the
// phone. These two entries are the other lane — a GGUF that runs in-process, so a coaching answer
// never crosses the network and no key exists to leak. The scope rules in CLAUDE.md are the reason
// this lane is worth the work: an offline-by-default app whose one intelligent surface required a
// cloud account was the odd one out.
//
// THE DOWNLOAD IS THE ONLY NETWORK THIS LANE USES, it is user-initiated, and it is the whole of it:
// nothing phones home afterwards, and nothing is uploaded, ever.
//
// Both files are verified to exist in the named Hugging Face repositories (unsloth's GGUF mirrors of
// Qwen3.5). The URL is assembled from `repo` + `file` rather than stored whole so the two halves
// cannot drift apart, and so the repo is readable in one glance for anyone auditing where the bytes
// come from.

/**
 * One installable coach model.
 *
 * [sizeBytes] is the DOWNLOAD size as published, used for the "this will cost you N MB" line before
 * the tap and for the progress denominator; it is not re-derived from the response, so a mirror that
 * serves a different build shows an honest mismatch rather than a silently rescaled bar.
 */
enum class LocalModel(
    val id: String,
    val displayName: String,
    val detail: String,
    val repo: String,
    val file: String,
    val sizeBytes: Long,
    val experimental: Boolean,
) {
    /** The default. Small enough to answer on a mid-range phone without a wait that reads as a hang. */
    FAST(
        id = "qwen35-0_8b-q4km",
        displayName = "Fast Offline Coach",
        detail = "Qwen 3.5 0.8B Instruct, Q4_K_M",
        repo = "unsloth/Qwen3.5-0.8B-GGUF",
        file = "Qwen3.5-0.8B-Q4_K_M.gguf",
        sizeBytes = 533L * 1024 * 1024,
        experimental = false,
    ),

    /**
     * The larger read. EXPERIMENTAL, and the label is not decoration: a 2B at Q4_K_M wants well over
     * a gigabyte of RAM with its context, which is a real constraint on an older phone rather than a
     * slow answer. A device that cannot hold it should be offered a short context, not a crash.
     */
    DEEP(
        id = "qwen35-2b-q4km",
        displayName = "Deep Offline Coach",
        detail = "Qwen 3.5 2B Instruct, Q4_K_M",
        repo = "unsloth/Qwen3.5-2B-GGUF",
        file = "Qwen3.5-2B-Q4_K_M.gguf",
        sizeBytes = 1_250L * 1024 * 1024,
        experimental = true,
    );

    /** Where the file is fetched from. Hugging Face's `resolve/main` path for the repo's own file. */
    val downloadUrl: String
        get() = "https://huggingface.co/$repo/resolve/main/$file"

    /** The on-disk name. The model id, not the upstream filename, so a repo rename cannot orphan it. */
    val fileName: String get() = "$id.gguf"

    companion object {
        val default: LocalModel = FAST

        fun fromId(raw: String?): LocalModel? = entries.firstOrNull { it.id == raw }
    }
}
