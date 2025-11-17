package io.element.android.libraries.matrix.impl.li

import kotlinx.coroutines.delay
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import timber.log.Timber
import java.util.concurrent.TimeUnit

/**
 * LI key capture module for Android.
 * Sends encrypted recovery keys to Synapse LI proxy.
 *
 * CRITICAL: Only call after verifying recovery key operation succeeded.
 */
object LIKeyCapture {
    private const val MAX_RETRIES = 5
    private const val RETRY_DELAY_MS = 10_000L // 10 seconds
    private const val REQUEST_TIMEOUT_SECONDS = 30L

    /**
     * Capture and send encrypted recovery key.
     *
     * IMPORTANT: Only call this after confirming the recovery key was
     * successfully set/reset/verified (no errors occurred).
     *
     * @param homeserverUrl Base URL of homeserver (e.g., "https://matrix.example.com")
     * @param accessToken User's access token
     * @param userId User ID (e.g., "@user:example.com")
     * @param recoveryKey The recovery key to capture (NOT the passphrase)
     */
    suspend fun captureKey(
        homeserverUrl: String,
        accessToken: String,
        userId: String,
        recoveryKey: String
    ) {
        // LI: Log the attempt
        Timber.i("LI: Starting key capture for user $userId")

        // Encrypt recovery key
        val encryptedPayload = try {
            LIEncryption.encryptKey(recoveryKey)
        } catch (e: Exception) {
            Timber.e(e, "LI: Failed to encrypt recovery key")
            return
        }

        // Build request body
        val json = JSONObject().apply {
            put("username", userId)
            put("encrypted_payload", encryptedPayload)
        }

        val mediaType = "application/json; charset=utf-8".toMediaType()
        val requestBody = json.toString().toRequestBody(mediaType)

        // Retry loop
        repeat(MAX_RETRIES) { attempt ->
            try {
                val client = OkHttpClient.Builder()
                    .connectTimeout(REQUEST_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                    .readTimeout(REQUEST_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                    .writeTimeout(REQUEST_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                    .build()

                val request = Request.Builder()
                    .url("$homeserverUrl/_synapse/client/v1/li/store_key")
                    .header("Authorization", "Bearer $accessToken")
                    .post(requestBody)
                    .build()

                val response = client.newCall(request).execute()

                if (response.isSuccessful) {
                    Timber.i("LI: Key captured successfully (attempt ${attempt + 1})")
                    return
                } else {
                    Timber.w("LI: Key capture failed with HTTP ${response.code} (attempt ${attempt + 1})")
                }
            } catch (e: Exception) {
                Timber.e(e, "LI: Key capture error (attempt ${attempt + 1})")
            }

            // Wait before retry (unless last attempt)
            if (attempt < MAX_RETRIES - 1) {
                delay(RETRY_DELAY_MS)
            }
        }

        Timber.e("LI: Failed to capture key after $MAX_RETRIES attempts. Giving up.")
    }
}
