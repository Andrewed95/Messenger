/**
 * LI encryption utilities for encrypting recovery keys
 * before sending to server.
 */

import { JSEncrypt } from 'jsencrypt';

// Hardcoded RSA public key (2048-bit)
// IMPORTANT: Replace with your actual public key
const RSA_PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA... (your key here)
-----END PUBLIC KEY-----`;

/**
 * Encrypt recovery key with RSA public key.
 *
 * @param plaintext - The recovery key to encrypt
 * @returns Base64-encoded encrypted payload
 */
export function encryptKey(plaintext: string): string {
    const encrypt = new JSEncrypt();
    encrypt.setPublicKey(RSA_PUBLIC_KEY);

    const encrypted = encrypt.encrypt(plaintext);
    if (!encrypted) {
        throw new Error('Encryption failed');
    }

    return encrypted;  // Already Base64-encoded by JSEncrypt
}
