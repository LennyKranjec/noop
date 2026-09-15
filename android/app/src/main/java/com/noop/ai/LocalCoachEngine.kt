package com.noop.ai

import android.content.Context
import android.os.Build
import com.arm.aichat.AiChat
import com.arm.aichat.InferenceEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.withContext

// MARK: - The on-device coach engine
//
// A thin seam over the checked-in llama.cpp AAR (see app/libs/README.md). It exists so the rest of
// the app never imports `com.arm.aichat` directly: the coach talks to THIS, and swapping the
// inference library later is one file rather than a search across the UI.
//
// WHAT IT GUARANTEES
//   · Nothing leaves the device. There is no endpoint, no key, no header — the model file is read
//     from NOOP's own storage and the tokens come back from the process it is loaded into.
//   · A device the native library cannot run on is told so ([isSupported]) instead of meeting an
//     UnsatisfiedLinkError. The AAR ships arm64-v8a only, which is every phone this realistically
//     runs on and no emulator image on an x86 laptop.
//   · Loading is explicit and one model at a time. A 0.8B at Q4_K_M is ~half a gigabyte resident
//     and the 2B is well past a gigabyte, so two loaded at once is not a state worth supporting.

object LocalCoachEngine {

    /**
     * Whether this device has the native library at all.
     *
     * ABI rather than a try/catch around a load: an unsupported device should be able to render an
     * honest "not supported on this phone" before the wearer downloads half a gigabyte, not after.
     */
    val isSupported: Boolean
        get() = Build.SUPPORTED_ABIS.any { it == "arm64-v8a" }

    private var engine: InferenceEngine? = null
    private var loadedModel: LocalModel? = null

    /**
     * ONE GENERATION AT A TIME. The engine holds a single model and a single conversation, and both a
     * chat turn and a scheduled job (a reminder's notification, the daily mission) want them. Left
     * unserialised, the background job's `loadModel` lands while the wearer's question is mid-flight
     * and the engine throws from a state neither caller chose.
     *
     * The wearer's conversation WAITS for the lane; background work only TRIES for it (see
     * [tryInLane]) and gives up, because a late notification is worse than a plain one.
     */
    private val lane = Mutex()

    /** Run [block] with exclusive use of the engine, waiting for anything already running. */
    suspend fun <T> inLane(block: suspend () -> T): T = lane.withLock { block() }

    /**
     * Run [block] only if the engine is free right now; null when it is not.
     *
     * Deliberately not a timeout: the thing that holds the lane is a person mid-conversation, and
     * there is no wait that is both long enough to help and short enough to be worth blocking a
     * worker for.
     */
    suspend fun <T> tryInLane(block: suspend () -> T): T? {
        if (!lane.tryLock()) return null
        return try {
            block()
        } finally {
            lane.unlock()
        }
    }

    /** The engine's own state, for a UI that wants to show "loading" / "generating" honestly. */
    fun state(context: Context): StateFlow<InferenceEngine.State> =
        AiChat.getInferenceEngine(context.applicationContext).state

    /** True when [model] is the one currently resident. */
    fun isLoaded(model: LocalModel): Boolean = loadedModel == model && engine != null

    /**
     * Make [model] the resident model, loading it from [LocalModelStore] if it is not already.
     *
     * Throws when the file is absent — the caller downloads first; this does not reach the network,
     * ever. Loading a different model unloads the previous one, because two do not fit.
     */
    suspend fun ensureLoaded(context: Context, model: LocalModel): Boolean {
        check(isSupported) { "This device has no arm64-v8a native library for the offline coach" }
        val file = LocalModelStore.fileFor(context, model)
        check(file.isFile && file.length() > 0) { "Model ${model.id} is not installed" }
        if (isLoaded(model) && !reloadPending) return false
        reloadPending = false

        val e = AiChat.getInferenceEngine(context.applicationContext)

        // THE ENGINE INITIALISES ITSELF ASYNCHRONOUSLY. `getInferenceEngine` returns immediately
        // while a coroutine inside it loads the native library and moves Uninitialized →
        // Initializing → Initialized. `loadModel` REQUIRES Initialized and throws
        // "Cannot load model in Uninitialized!" otherwise — which is exactly the race the first cut
        // of this shipped into, because it called loadModel on the line after this one.
        //
        // IDLE IS TWO STATES, NOT ONE. A freshly initialised engine sits in Initialized; one with a
        // model resident sits in ModelReady and NEVER returns to Initialized except through
        // cleanUp(). Waiting for Initialized here therefore waited forever on every RELOAD — which is
        // every "stop generating", every new chat, every model switch — and the wearer watched the
        // coach think about a question it had not been given yet. The hang looked exactly like a
        // model stuck in a loop, which is why it was mistaken for one.
        val idle = e.awaitIdle()

        // Anything resident has to go before a load, and so does a latched Error: cleanUp() is the
        // engine's only route back to Initialized from either. Doing this unconditionally on state
        // (rather than on our own `loadedModel`) also recovers an engine that some other holder left
        // loaded, instead of throwing "Cannot load model in ModelReady!" at the wearer.
        if (idle !is InferenceEngine.State.Initialized) {
            // cleanUp() is BLOCKING (runBlocking on the engine's own dispatcher) and waits for a
            // generation in flight to notice its cancel flag, then unloads half a gigabyte. On the
            // main thread that is an ANR, so it is pushed off it.
            withContext(Dispatchers.IO) { e.cleanUp() }
            engine = null
            loadedModel = null
            acceptsSystemPrompt = false
            e.awaitIdle()
        }
        e.loadModel(file.absolutePath)
        engine = e
        loadedModel = model
        // The ONE window in which a system prompt is accepted has just opened.
        acceptsSystemPrompt = true
        return true
    }

    /**
     * Suspend until the engine is between jobs, and say which resting state it landed in.
     *
     * The engine's working states (Initializing, LoadingModel, ProcessingSystemPrompt,
     * ProcessingUserPrompt, Generating, UnloadingModel) all end by themselves; the three below do
     * not, and each needs something different from the caller — so this waits for any of them and
     * hands back which, rather than pretending there is one "ready".
     *
     * Error is RETURNED, not thrown. The engine latches it until a cleanUp() clears it, so throwing
     * here would make one bad load poison every question afterwards with no way back short of
     * force-quitting the app.
     */
    private suspend fun InferenceEngine.awaitIdle(): InferenceEngine.State = state.first {
        it is InferenceEngine.State.Initialized ||
            it is InferenceEngine.State.ModelReady ||
            it is InferenceEngine.State.Error
    }

    /** True only between a completed load and the first system prompt that follows it. */
    private var acceptsSystemPrompt = false

    /** Set when the next question must start from a freshly loaded model (see [resetConversation]). */
    private var reloadPending = false

    /**
     * Set the coaching persona + grounding.
     *
     * THE ENGINE ACCEPTS THIS EXACTLY ONCE PER LOAD. `_readyForSystemPrompt` is raised when a model
     * finishes loading and consumed by the first call; a second one throws "System prompt must be
     * set ** RIGHT AFTER ** model loaded!". So this is a no-op outside that window rather than an
     * error — the grounding is re-read on every send and would otherwise differ (the day's numbers
     * move), and an attempt to re-state it would have taken down the conversation it was trying to
     * improve. The grounding therefore describes the moment the model was loaded; starting a new
     * chat reloads it, which is where a fresher picture comes from.
     */
    suspend fun setSystemPrompt(prompt: String) {
        if (!acceptsSystemPrompt) return
        acceptsSystemPrompt = false
        engine?.setSystemPrompt(prompt)
    }

    /**
     * Ask the resident model, streaming tokens as they are produced.
     *
     * An empty flow when nothing is loaded rather than an exception: a coach screen that has not
     * finished loading should render nothing yet, not crash mid-composition.
     */
    fun ask(message: String): Flow<String> = engine?.sendUserPrompt(message) ?: emptyFlow()

    /**
     * Give up the resident model. Safe to call when nothing is loaded.
     *
     * DEFERRED, NOT IMMEDIATE. The engine's cleanUp() blocks the calling thread while it waits out
     * any generation in flight and frees half a gigabyte, and every caller here is a tap handler on
     * the main thread — so the unload is left to the next [ensureLoaded], which does it off the main
     * thread anyway. Nothing is answered from the old model in the meantime: [loadedModel] is
     * cleared, so the next question reloads before it is asked.
     */
    fun unload() {
        engine = null
        loadedModel = null
        acceptsSystemPrompt = false
        reloadPending = true
    }

    /**
     * Start the next question from a clean model.
     *
     * A RELOAD IS THE ONLY WAY TO FORGET. The engine holds the conversation internally and offers no
     * "clear context", and its system-prompt window only reopens on a load — so a new chat that kept
     * the resident model would answer with the old thread still in mind, on stale grounding. The
     * cost is the load time on the next question, paid once, for the thing the wearer just asked for.
     */
    fun resetConversation() {
        reloadPending = true
    }
}
