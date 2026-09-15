# `libs/` — the on-device inference AAR

One checked-in binary lives here, and this file is why it is allowed to.

## What it is

`llama-android-1bc7a5a-noop2.aar` — llama.cpp's own Android library module
(`examples/llama.android/lib`, upstream's "AiChat" module), built from source. It carries the JNI
glue plus the native libraries for **arm64-v8a only**:

```
jni/arm64-v8a/libai-chat.so       the JNI bridge
jni/arm64-v8a/libllama.so         llama.cpp
jni/arm64-v8a/libllama-common.so
jni/arm64-v8a/libggml*.so         the tensor backends
jni/arm64-v8a/libomp.so           OpenMP
```

Kotlin surface: `com.arm.aichat.AiChat.getInferenceEngine(context)` →
`loadModel(path)`, `setSystemPrompt(...)`, `sendUserPrompt(...): Flow<String>` (streaming tokens),
`cleanUp()`, and a `StateFlow<State>`.

## Why a checked-in binary rather than a dependency

There is **no llama.cpp AAR on Maven Central**. The Java bindings published there
(`de.kherud:llama`, `io.gravitee.llama.cpp:llamaj.cpp`) ship desktop natives, not Android `.so`
files, and the Android-specific bindings that advertise Maven coordinates are not actually published
under them. The remaining option was a JitPack build of a community fork — an unsigned artifact built
from an arbitrary GitHub state, with no publisher to verify a checksum against, which is the wrong
thing to put in the inference path of a clean-room, offline-by-default app.

Building it ourselves keeps the supply chain to: upstream llama.cpp source → our own NDK → this file.
As a local file dependency it also never enters `gradle.lockfile` /
`gradle/verification-metadata.xml`, because nothing is resolved from a repository.

## Provenance — how to reproduce it

Source: <https://github.com/ggml-org/llama.cpp> at commit **`1bc7a5a`**.

```bash
git clone https://github.com/ggml-org/llama.cpp.git && cd llama.cpp
git checkout 1bc7a5a
cd examples/llama.android
# then apply the six fork edits below, and:
java -cp gradle/wrapper/gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain :lib:assembleRelease
# output: lib/build/outputs/aar/lib-release.aar
```

### The fork edits, and why each was needed

Upstream's example targets a modern phone, assumes a fresh toolchain, and was tuned on a model large
enough to forgive its sampler. NOOP ships to Android 8.0, pins its own versions, and runs a 0.8B, so
six things had to change. Five are in the BUILD; the sixth is the sampler configuration, which is the
only one that touches how a reply is produced.

| Edit | From | To | Why |
|---|---|---|---|
| `lib/build.gradle.kts` `minSdk` | 33 | 26 | NOOP's `minSdk` is 26; an AAR at 33 cannot be consumed without dropping Android 8–12. |
| `lib/build.gradle.kts` `compileSdk` / `aarMetadata.minCompileSdk` | 36 / 35 | 35 / 34 | NOOP compiles against 34. |
| `lib/build.gradle.kts` deps | `androidx.core.ktx`, `androidx.datastore.preferences` | removed; `kotlinx-coroutines-android:1.8.1` added | Neither androidx artifact is imported anywhere in the module — they are leftovers — and `androidx.core:core:1.17.0` forces `compileSdk 36` on every consumer. Coroutines arrived transitively through core-ktx, so they are now declared directly, at the version NOOP itself resolves. |
| `lib/build.gradle.kts` ABI / variants | `arm64-v8a` + `x86_64`, `GGML_CPU_ALL_VARIANTS=ON`, `GGML_BACKEND_DL=ON` | `arm64-v8a`, both `=OFF` | The x86 dispatch variants (alderlake, cooperlake, sapphirerapids …) cannot run on any phone this ships to, and building them all needs several GB. Add x86_64 back if an emulator build is ever wanted. **`GGML_BACKEND_DL` and `GGML_CPU_ALL_VARIANTS` are one setting in two halves — see below.** |
| `lib/src/main/cpp/logging.h` | `__android_log_is_loggable(...)` | guarded by `#if __ANDROID_API__ >= 30` | That symbol arrived in API 30. Below it, the helper falls back to the compile-time threshold the log macros already gate on. Behaviour on API 30+ is unchanged. |
| `lib/src/main/java/.../InferenceEngineImpl.kt` | every `external fun` marked `@FastNative` | annotation removed | See below — it crashes the process on a slower phone. |
| `lib/src/main/cpp/ai_chat.cpp` `new_sampler()` / `DEFAULT_SAMPLER_TEMP` | temperature 0.3, everything else default | `penalty_repeat 1.1` / `penalty_last_n 256`, DRY on, `top_k 20` / `top_p 0.8` / `min_p 0`, temp 0.7 | See below — upstream ships with BOTH repetition guards disabled. |

### `@FastNative` on a long call aborts the process

`@FastNative` promises ART the call is short, and in exchange the thread cannot be suspended for the
duration. Upstream marks EVERY native entry point with it, including `load` (which reads a
half-gigabyte model) and the prompt/token calls (seconds of compute). On a Mi 9T Pro the GC tried to
suspend that worker, could not, and the runtime killed the app:

```
F libc  : Fatal signal 6 (SIGABRT) ... in tid … (DefaultDispatch)
F DEBUG : Abort message: 'Thread suspension timed out: 0x…:DefaultDispatcher-worker-3'
```

A normal JNI transition costs tens of nanoseconds against work measured in milliseconds to seconds,
so the annotation buys nothing here and costs the process. Removed from all of them.

### The sampler ships with both repetition guards switched off

`new_sampler()` upstream sets the temperature and nothing else, so it inherits
`common_params_sampling`'s defaults — and two of those defaults are the disabled values:

```cpp
int32_t penalty_last_n  = 64;
float   penalty_repeat  = 1.00f;  // 1.0 = disabled
float   dry_multiplier  = 0.0f;   // 0.0 = disabled
```

The chain in `samplers` *contains* `COMMON_SAMPLER_TYPE_PENALTIES` and `COMMON_SAMPLER_TYPE_DRY`;
they are just no-ops. Combined with the 0.3 temperature, which is nearly greedy, a 0.8B model locks
into a repetition attractor on roughly the first question: the phrase it has just written becomes the
most likely continuation of itself and nothing in the chain pushes back. The symptom is a reply that
restates the same sentence until the token budget runs out.

Fixed by configuring what was already in the chain — a flat repeat penalty over 256 tokens, DRY
scanning the whole context (it penalises repeated *sequences*, which is what a stuck model emits) —
and by moving the sampling to the settings Qwen publishes for answering without a reasoning block
(temp 0.7, top_k 20, top_p 0.8, min_p 0).

### `GGML_BACKEND_DL` must not outlive `GGML_CPU_ALL_VARIANTS`

Turning the variants off while leaving `GGML_BACKEND_DL=ON` produces an AAR that builds, installs,
loads its native library — and then refuses every model:

```
ai-chat : Loading backends from /data/.../lib/arm64
ai-chat : llama_model_load_from_file_impl: no backends are loaded.
```

`GGML_BACKEND_DL` exists to pick the best CPU variant at RUNTIME, by dlopening the per-variant
backend libraries that `GGML_CPU_ALL_VARIANTS` produces. With no variants built there is nothing for
it to find, no backend registers, and llama.cpp rejects the model. The two options are a pair: turn
them off together (this fork) or on together (upstream).

Worth knowing because the symptom lies: the engine maps every non-zero load code to
`UnsupportedArchitectureException`, so a missing backend is reported as an unsupported model.
Check logcat for `no backends are loaded` before believing the architecture is the problem.

`ndkVersion` and the CMake version were also pinned to what the build machine had (NDK
`28.2.13676358`, CMake 3.22) rather than upstream's NDK 29 / CMake 3.31.6. The module's own
`CMakeLists.txt` uses nothing specific to 3.31, and llama.cpp's root asks only for 3.14.

## Updating it

Rebuild from a newer llama.cpp commit with the same edits, replace the file, and update the commit
hash in this document and in the filename. The filename carries the hash so a stale binary and its
provenance cannot drift apart.

The `-noopN` suffix is the FORK revision at the same upstream commit: bump it whenever the edits above
change without the commit moving, so a rebuilt binary can never keep the name of the one it replaced.
`-noop2` is the sampler fix; `-noop1` (unsuffixed) was the original build. Bumping it also forces the
`implementation(files(...))` line in `app/build.gradle.kts` to be updated, which is what catches a
build still linking the old binary.
