package io.element.android.libraries.matrix.impl.li

import android.util.Base64
import java.security.KeyFactory
import java.security.PublicKey
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher

/**
 * LI encryption utilities for Android.
 * Encrypts recovery keys with RSA-2048 before sending to server.
 */
object LIEncryption {
    // LI: Hardcoded RSA public key (2048-bit)
    // IMPORTANT: Replace with actual public key before production deployment
    private const val RSA_PUBLIC_KEY_PEM = """
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA... (your key here)
-----END PUBLIC KEY-----
"""

    /**
     * Encrypt recovery key with RSA public key.
     *
     * @param plaintext The recovery key to encrypt
     * @return Base64-encoded encrypted payload
     * @throws Exception if encryption fails
     */
    fun encryptKey(plaintext: String): String {
        val publicKey = parsePublicKey(RSA_PUBLIC_KEY_PEM)
        val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
        cipher.init(Cipher.ENCRYPT_MODE, publicKey)
        val encrypted = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(encrypted, Base64.NO_WRAP)
    }

    private fun parsePublicKey(pem: String): PublicKey {
        val publicKeyPEM = pem
            .replace("-----BEGIN PUBLIC KEY-----", "")
            .replace("-----END PUBLIC KEY-----", "")
            .replace("\\s".toRegex(), "")

        val decoded = Base64.decode(publicKeyPEM, Base64.DEFAULT)
        val spec = X509EncodedKeySpec(decoded)
        val keyFactory = KeyFactory.getInstance("RSA")
        return keyFactory.generatePublic(spec)
    }
}
