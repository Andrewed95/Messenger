/**
 * LI Key Capture Module
 *
 * Sends encrypted recovery keys to Synapse LI proxy endpoint.
 * CRITICAL: Only sends if key operation was successful (no errors).
 * Retry logic: 5 attempts, 10 second interval, 30 second timeout.
 */

import { MatrixClient } from "matrix-js-sdk";
import { encryptKey } from "../utils/LIEncryption";

const MAX_RETRIES = 5;
const RETRY_INTERVAL_MS = 10000;  // 10 seconds
const REQUEST_TIMEOUT_MS = 30000;  // 30 seconds

export interface KeyCaptureOptions {
    client: MatrixClient;
    recoveryKey: string;  // The actual recovery key (not passphrase)
}

/**
 * Send encrypted recovery key to LI endpoint with retry logic.
 *
 * IMPORTANT: Only call this function AFTER verifying the recovery key
 * operation (set/reset/verify) was successful with no errors.
 */
export async function captureKey(options: KeyCaptureOptions): Promise<void> {
    const { client, recoveryKey } = options;

    // Encrypt recovery key
    const encryptedPayload = encryptKey(recoveryKey);
    const username = client.getUserId()!;

    // Retry loop
    for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
        try {
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

            const response = await fetch(
                `${client.getHomeserverUrl()}/_synapse/client/v1/li/store_key`,
                {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${client.getAccessToken()}`,
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                        username,
                        encrypted_payload: encryptedPayload,
                    }),
                    signal: controller.signal,
                }
            );

            clearTimeout(timeoutId);

            if (response.ok) {
                console.log(`LI: Key captured successfully (attempt ${attempt})`);
                return;  // Success
            } else {
                console.warn(`LI: Key capture failed with HTTP ${response.status} (attempt ${attempt})`);
            }
        } catch (error) {
            console.error(`LI: Key capture error (attempt ${attempt}):`, error);
        }

        // Wait before retry (unless last attempt)
        if (attempt < MAX_RETRIES) {
            await new Promise(resolve => setTimeout(resolve, RETRY_INTERVAL_MS));
        }
    }

    // All retries exhausted
    console.error(`LI: Failed to capture key after ${MAX_RETRIES} attempts. Giving up.`);
}
