package com.noop.ai

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.coroutineContext

// MARK: - Installing and holding the on-device coach models
//
// Files live in the app's own `files/models` directory: private to NOOP, wiped with an uninstall,
// and never in shared storage where another app could read what the wearer chose to run. There is
// no content provider onto it and nothing exports it.
//
// DOWNLOAD SAFETY. A model arrives over one plain HTTPS GET into a `.part` file and is renamed into
// place only once the byte count matches what the catalogue expects. That rename is the whole
// commit: a killed download, a dropped connection or a truncated mirror leaves a `.part` behind and
// the model reads as absent, which is the honest state. Nothing resumes yet — a half file is
// discarded rather than trusted, and the retry starts clean.

object LocalModelStore {

    private const val PREFS = "noop_local_coach"
    private const val KEY_SELECTED = "selected_model"

    /** A download's progress, as the UI needs it. [total] is the catalogue size, never zero. */
    data class Progress(val downloadedBytes: Long, val total: Long) {
        val fraction: Float get() = if (total <= 0) 0f else (downloadedBytes.toFloat() / total).coerceIn(0f, 1f)
    }

    private fun dir(context: Context): File =
        File(context.filesDir, "models").apply { if (!exists()) mkdirs() }

    fun fileFor(context: Context, model: LocalModel): File = File(dir(context), model.fileName)

    /** True when the model is installed and whole. A `.part` is not installed. */
    fun isInstalled(context: Context, model: LocalModel): Boolean =
        fileFor(context, model).let { it.isFile && it.length() > 0 }

    /** Bytes on disk for [model], or 0 when it is not installed. */
    fun installedBytes(context: Context, model: LocalModel): Long =
        fileFor(context, model).takeIf { it.isFile }?.length() ?: 0L

    /** Which model the coach should use. Falls back to [LocalModel.default] — never to nothing. */
    fun selected(context: Context): LocalModel =
        LocalModel.fromId(
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_SELECTED, null),
        ) ?: LocalModel.default

    fun setSelected(context: Context, model: LocalModel) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY_SELECTED, model.id).apply()
    }

    /** Remove an installed model. Returns true when a file was actually deleted. */
    fun delete(context: Context, model: LocalModel): Boolean = fileFor(context, model).delete()

    /**
     * Fetch [model] into place, reporting progress.
     *
     * Cancellable: the coroutine's cancellation is checked every chunk, and a cancelled download
     * leaves only the `.part` file, which the next attempt overwrites. Returns the installed file,
     * or throws — the caller renders the failure rather than this pretending a model is present.
     */
    suspend fun download(
        context: Context,
        model: LocalModel,
        onProgress: (Progress) -> Unit,
    ): File = withContext(Dispatchers.IO) {
        val target = fileFor(context, model)
        if (target.isFile && target.length() > 0) return@withContext target

        val part = File(dir(context), model.fileName + ".part")
        if (part.exists()) part.delete()

        val connection = (URL(model.downloadUrl).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            instanceFollowRedirects = true
            connectTimeout = 30_000
            readTimeout = 60_000
        }
        try {
            val code = connection.responseCode
            if (code !in 200..299) error("Download failed with HTTP $code")
            // The server's own length when it gives one, the catalogue's when it does not — a
            // progress bar with a guessed denominator is worse than one that is honest about size.
            val declared = connection.contentLengthLong.takeIf { it > 0 } ?: model.sizeBytes

            connection.inputStream.use { input ->
                part.outputStream().use { output ->
                    val buffer = ByteArray(1 shl 16)
                    var copied = 0L
                    while (true) {
                        coroutineContext.ensureActive()
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        copied += read
                        onProgress(Progress(copied, declared))
                    }
                }
            }
        } finally {
            connection.disconnect()
        }

        // The rename IS the commit. Anything that went wrong above leaves a `.part` and no model.
        if (!part.renameTo(target)) {
            part.delete()
            error("Could not move the downloaded model into place")
        }
        target
    }
}
