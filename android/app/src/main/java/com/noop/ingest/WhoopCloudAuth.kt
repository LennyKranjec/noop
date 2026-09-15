package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.BuildConfig
import com.noop.data.SecurePrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.security.SecureRandom
import java.util.concurrent.TimeUnit

// MARK: - Signing in to WHOOP's cloud
//
// The OAuth 2.0 authorisation-code flow, which is what WHOOP's developer platform offers. The wearer is
// sent to WHOOP in a browser, comes back to `noop://whoop-oauth?code=…`, and the code is exchanged here
// for an access token and a refresh token.
//
// THE CLIENT SECRET IS IN THE APK, AND THAT IS A REAL WEAKNESS, not a detail. WHOOP's token endpoint
// requires `client_secret` and their flow has no PKCE-only public-client mode, so a mobile app has no
// way to hold this safely: anyone who unpacks the APK has the secret. It is kept out of the repository
// (`local.properties`, git-ignored) so it is not published with the source, and that is the whole of
// what this app can do about it. For a build the wearer installs on their own phone that is an
// acceptable trade; for a distributed build it is not, and the honest fix would be a token exchange on
// a server the wearer controls.
//
// TOKENS LIVE IN THE ENCRYPTED STORE, the same Keystore-backed file the AI keys use — never in plain
// preferences, and never written to a log.
//
// NOT CONFIGURED IS A FIRST-CLASS STATE. A clone with no credentials in `local.properties` builds and
// runs; [isConfigured] is false and the UI simply does not offer the connection. Nothing here throws
// because a key is missing.

object WhoopCloudAuth {

    private const val FILE_NAME = "noop_whoop_secure_prefs"
    private const val KEY_ACCESS = "access_token"
    private const val KEY_REFRESH = "refresh_token"
    private const val KEY_EXPIRES_AT = "expires_at"
    private const val KEY_STATE = "pending_state"

    private const val AUTH_URL = "https://api.prod.whoop.com/oauth/oauth2/auth"
    private const val TOKEN_URL = "https://api.prod.whoop.com/oauth/oauth2/token"

    /**
     * What the app asks for.
     *
     * `offline` is the one that is not a data scope: it is what makes WHOOP return a REFRESH token, and
     * without it the connection would die an hour after it was made and the wearer would have to sign in
     * again every time they opened the app.
     */
    private const val SCOPES =
        "read:recovery read:cycles read:sleep read:workout read:profile offline"

    /** Refresh this long before the token actually expires, so a sync never races the clock. */
    private const val EXPIRY_SKEW_SEC = 120L

    private val http: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    /** True when this build carries credentials at all. False is normal, not an error. */
    val isConfigured: Boolean
        get() = BuildConfig.WHOOP_CLIENT_ID.isNotBlank() && BuildConfig.WHOOP_CLIENT_SECRET.isNotBlank()

    /** True when the wearer has completed a sign-in and a refresh token is held. */
    fun isConnected(context: Context): Boolean =
        !prefs(context).getString(KEY_REFRESH, null).isNullOrBlank()

    /**
     * The URL to open in a browser, and the `state` it is bound to.
     *
     * The state is random per attempt and stored, so the redirect can be checked against it — without
     * that, any app that can claim the `noop://` scheme could hand this one a code of its own choosing.
     */
    fun authorizeUrl(context: Context): String {
        val state = randomState()
        prefs(context).edit().putString(KEY_STATE, state).apply()
        return Uri.parse(AUTH_URL).buildUpon()
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("client_id", BuildConfig.WHOOP_CLIENT_ID)
            .appendQueryParameter("redirect_uri", BuildConfig.WHOOP_REDIRECT_URI)
            .appendQueryParameter("scope", SCOPES)
            .appendQueryParameter("state", state)
            .build()
            .toString()
    }

    /**
     * Finish the flow from the redirect.
     *
     * Returns false for anything that is not a clean, expected redirect: a mismatched state, an error
     * from WHOOP, a missing code, or a failed exchange. The caller shows "could not connect" rather
     * than guessing which — the wearer's next move is the same for all of them.
     */
    suspend fun completeFrom(context: Context, redirect: Uri): Boolean {
        val expected = prefs(context).getString(KEY_STATE, null)
        val state = redirect.getQueryParameter("state")
        // Cleared whether or not it matched: a state is good for exactly one attempt.
        prefs(context).edit().remove(KEY_STATE).apply()
        if (expected.isNullOrBlank() || state != expected) return false
        val code = redirect.getQueryParameter("code")?.takeIf { it.isNotBlank() } ?: return false
        return exchange(context, code)
    }

    /**
     * A valid access token, refreshing when it is close to expiry, or null when not connected.
     *
     * Every caller goes through this rather than reading the stored token, so there is one place that
     * knows when a refresh is due.
     */
    suspend fun accessToken(context: Context): String? {
        val p = prefs(context)
        val token = p.getString(KEY_ACCESS, null)
        val expiresAt = p.getLong(KEY_EXPIRES_AT, 0L)
        val now = System.currentTimeMillis() / 1000L
        if (!token.isNullOrBlank() && now < expiresAt - EXPIRY_SKEW_SEC) return token
        return if (refresh(context)) p.getString(KEY_ACCESS, null) else null
    }

    /** Forget the connection. The tokens go; nothing that was already synced is touched. */
    fun disconnect(context: Context) {
        prefs(context).edit()
            .remove(KEY_ACCESS)
            .remove(KEY_REFRESH)
            .remove(KEY_EXPIRES_AT)
            .remove(KEY_STATE)
            .apply()
    }

    private suspend fun exchange(context: Context, code: String): Boolean = post(
        context,
        FormBody.Builder()
            .add("grant_type", "authorization_code")
            .add("code", code)
            .add("client_id", BuildConfig.WHOOP_CLIENT_ID)
            .add("client_secret", BuildConfig.WHOOP_CLIENT_SECRET)
            .add("redirect_uri", BuildConfig.WHOOP_REDIRECT_URI)
            .build(),
    )

    private suspend fun refresh(context: Context): Boolean {
        val refreshToken = prefs(context).getString(KEY_REFRESH, null)?.takeIf { it.isNotBlank() }
            ?: return false
        return post(
            context,
            FormBody.Builder()
                .add("grant_type", "refresh_token")
                .add("refresh_token", refreshToken)
                .add("client_id", BuildConfig.WHOOP_CLIENT_ID)
                .add("client_secret", BuildConfig.WHOOP_CLIENT_SECRET)
                // WHOOP re-issues a refresh token only when `offline` is asked for again.
                .add("scope", "offline")
                .build(),
        )
    }

    /**
     * One token-endpoint round trip, storing whatever came back.
     *
     * Never throws: a dead network, a rejected refresh and a malformed body all read as false, and the
     * connection is left exactly as it was so the next attempt can try again.
     */
    private suspend fun post(context: Context, form: FormBody): Boolean = withContext(Dispatchers.IO) {
        runCatching {
            val request = Request.Builder().url(TOKEN_URL).post(form).build()
            http.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use false
                val body = response.body?.string().orEmpty()
                val json = JSONObject(body)
                val access = json.optString("access_token", "")
                if (access.isBlank()) return@use false
                val editor = prefs(context).edit().putString(KEY_ACCESS, access)
                // A refresh response may omit the refresh token, which means KEEP the one held — a
                // blanket write would sign the wearer out on the first refresh that did not re-issue.
                json.optString("refresh_token", "").takeIf { it.isNotBlank() }
                    ?.let { editor.putString(KEY_REFRESH, it) }
                val ttl = json.optLong("expires_in", 3600L)
                editor.putLong(KEY_EXPIRES_AT, System.currentTimeMillis() / 1000L + ttl)
                editor.apply()
                true
            }
        }.getOrDefault(false)
    }

    private fun prefs(context: Context) = SecurePrefs.of(context.applicationContext, FILE_NAME)

    private fun randomState(): String {
        val bytes = ByteArray(24)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
