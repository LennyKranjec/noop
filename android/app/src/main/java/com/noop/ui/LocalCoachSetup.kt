package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.ai.LocalCoachEngine
import com.noop.ai.LocalModel
import com.noop.ai.LocalModelStore
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.util.Locale

// MARK: - The offline coach's setup: two models, no key
//
// This replaced a provider picker and an API-key field. There is no key here because there is no
// request: the model runs in this process, so a coaching answer never leaves the phone and there is
// no credential to store, leak or revoke. The ONE network call this screen can make is the model
// download itself, which is explicit, user-initiated and shown with its size before the tap.
//
// The two entries are [LocalModel.FAST] and [LocalModel.DEEP] — see that file for what they are and
// where the bytes come from.

@Composable
internal fun LocalCoachSetup() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // Recomposition trigger: file presence is not observable state, so a completed download or a
    // delete bumps this to re-read the disk.
    var revision by remember { mutableStateOf(0) }
    var selected by remember { mutableStateOf(LocalModelStore.selected(context)) }
    var downloading by remember { mutableStateOf<LocalModel?>(null) }
    var progress by remember { mutableStateOf(0f) }
    var error by remember { mutableStateOf<String?>(null) }
    var job by remember { mutableStateOf<Job?>(null) }

    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Filled.CloudOff,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(Metrics.iconSmall),
                )
                Spacer(Modifier.width(Metrics.space8))
                Text(
                    uiString(R.string.coach_local_title),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
            }
            Text(
                uiString(R.string.coach_local_body),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )

            if (!LocalCoachEngine.isSupported) {
                // Said BEFORE any download button: half a gigabyte fetched onto a device that can
                // never run it is the worst possible order to discover this in.
                Text(
                    uiString(R.string.coach_local_unsupported),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                )
                return@Column
            }

            LocalModel.entries.forEach { model ->
                key(revision, model) {
                    ModelRow(
                        model = model,
                        installed = LocalModelStore.isInstalled(context, model),
                        isSelected = selected == model,
                        isDownloading = downloading == model,
                        progress = progress,
                        onSelect = {
                            selected = model
                            LocalModelStore.setSelected(context, model)
                        },
                        onDownload = {
                            error = null
                            downloading = model
                            progress = 0f
                            job = scope.launch {
                                try {
                                    LocalModelStore.download(context, model) {
                                        progress = it.fraction
                                    }
                                    selected = model
                                    LocalModelStore.setSelected(context, model)
                                } catch (e: Exception) {
                                    error = e.message ?: "Download failed"
                                } finally {
                                    downloading = null
                                    revision++
                                }
                            }
                        },
                        onCancel = {
                            job?.cancel()
                            job = null
                            downloading = null
                            revision++
                        },
                        onDelete = {
                            LocalModelStore.delete(context, model)
                            revision++
                        },
                    )
                }
            }

            error?.let {
                Text(it, style = NoopType.footnote, color = Palette.statusCritical)
            }

            Text(
                uiString(R.string.coach_local_privacy_note),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun ModelRow(
    model: LocalModel,
    installed: Boolean,
    isSelected: Boolean,
    isDownloading: Boolean,
    progress: Float,
    onSelect: () -> Unit,
    onDownload: () -> Unit,
    onCancel: () -> Unit,
    onDelete: () -> Unit,
) {
    val border = if (isSelected && installed) Palette.accent else Palette.hairline
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cornerSm))
            .background(Palette.surfaceInset)
            .clickable(enabled = installed) { onSelect() }
            .padding(Metrics.space12),
        verticalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(model.displayName, style = NoopType.body, color = Palette.textPrimary)
                    if (model.experimental) {
                        Spacer(Modifier.width(Metrics.space8))
                        StatePill(
                            uiString(R.string.coach_local_experimental),
                            tone = StrandTone.Warning,
                            showsDot = false,
                        )
                    }
                }
                Text(model.detail, style = NoopType.footnote, color = Palette.textTertiary)
                if (model.experimental) {
                    Text(
                        uiString(R.string.coach_local_deep_note),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }
            Spacer(Modifier.width(Metrics.space8))
            when {
                isDownloading -> Text(
                    "${(progress * 100).toInt()} %",
                    style = NoopType.captionNumber,
                    color = Palette.textSecondary,
                )
                installed && isSelected -> Icon(
                    Icons.Filled.CheckCircle,
                    contentDescription = null,
                    tint = Palette.statusPositive,
                    modifier = Modifier.size(Metrics.iconSmall),
                )
                installed -> Text(
                    uiString(R.string.coach_local_use),
                    style = NoopType.footnote,
                    color = Palette.accent,
                )
                else -> Text(
                    formatSize(model.sizeBytes),
                    style = NoopType.captionNumber,
                    color = Palette.textTertiary,
                )
            }
        }

        if (isDownloading) {
            ProgressTrackLine(progress = progress, color = Palette.accent)
        }

        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
            when {
                isDownloading -> NoopButton(
                    text = uiString(R.string.coach_local_cancel),
                    kind = NoopButtonKind.Secondary,
                    onClick = onCancel,
                )
                installed -> NoopButton(
                    text = uiString(R.string.coach_local_remove),
                    leadingIcon = Icons.Filled.Delete,
                    kind = NoopButtonKind.Secondary,
                    onClick = onDelete,
                )
                else -> NoopButton(
                    text = uiString(R.string.coach_local_download),
                    leadingIcon = Icons.Filled.Download,
                    kind = if (model.experimental) NoopButtonKind.Secondary else NoopButtonKind.Primary,
                    onClick = onDownload,
                )
            }
        }
        // The selected ring is drawn as a hairline under the row rather than a border around it, so a
        // row can be selected AND mid-download without two competing outlines.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = Metrics.space2)
                .background(border)
                .size(width = 0.dp, height = Metrics.divider),
        )
    }
}

@Composable
private fun ProgressTrackLine(progress: Float, color: androidx.compose.ui.graphics.Color) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cornerPill))
            .background(Palette.surfaceBase)
            .size(width = 0.dp, height = 6.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(progress.coerceIn(0f, 1f))
                .clip(RoundedCornerShape(Metrics.cornerPill))
                .background(color)
                .size(width = 0.dp, height = 6.dp),
        )
    }
}

private fun formatSize(bytes: Long): String =
    String.format(Locale.US, "%.0f MB", bytes / (1024.0 * 1024.0))
