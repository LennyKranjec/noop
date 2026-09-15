package com.noop.ingest

import android.app.Activity
import android.os.Bundle
import android.widget.Toast
import com.noop.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// MARK: - Catching the WHOOP redirect
//
// WHOOP sends the wearer back to `noop://whoop-oauth?code=…&state=…` when they approve. This activity
// exists only to receive that, hand it to [WhoopCloudAuth], and get out of the way.
//
// NO UI AT ALL. It has no layout and finishes as soon as the exchange resolves — a screen here would be
// a screen the wearer sees for a second on the way back into the app, and there is nothing on it they
// could act on. The outcome is a toast, because this runs outside any screen that could show a state.
//
// THE EXCHANGE IS NOT CANCELLED BY THE FINISH. It runs on an application-scoped coroutine rather than
// the activity's own, so closing this does not abandon a token exchange mid-flight and leave the wearer
// signed out after apparently approving.

class WhoopOAuthActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val data = intent?.data
        val app = applicationContext

        if (data == null) {
            finish()
            return
        }

        CoroutineScope(Dispatchers.IO).launch {
            val ok = runCatching { WhoopCloudAuth.completeFrom(app, data) }.getOrDefault(false)
            withContext(Dispatchers.Main) {
                Toast.makeText(
                    app,
                    app.getString(
                        if (ok) R.string.whoop_cloud_connected else R.string.whoop_cloud_connect_failed,
                    ),
                    Toast.LENGTH_LONG,
                ).show()
            }
        }
        finish()
    }
}
