// LI: RSA decryption tool for decrypting captured recovery keys
// This page is ONLY for synapse-admin-li (hidden instance)

import {
  Box,
  Button,
  Card,
  CardContent,
  Container,
  TextField,
  Typography,
  Alert,
} from "@mui/material";
import { useState } from "react";
import { Title } from "react-admin";

export const DecryptionPage = () => {
  const [privateKey, setPrivateKey] = useState("");
  const [encryptedPayload, setEncryptedPayload] = useState("");
  const [decrypted, setDecrypted] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  // LI: Helper function to convert PEM to ArrayBuffer
  const pemToArrayBuffer = (pem: string): ArrayBuffer => {
    const pemHeader = "-----BEGIN PRIVATE KEY-----";
    const pemFooter = "-----END PRIVATE KEY-----";
    const pemContents = pem
      .replace(pemHeader, "")
      .replace(pemFooter, "")
      .replace(/\\s/g, "");

    const binaryString = window.atob(pemContents);
    const bytes = new Uint8Array(binaryString.length);
    for (let i = 0; i < binaryString.length; i++) {
      bytes[i] = binaryString.charCodeAt(i);
    }
    return bytes.buffer;
  };

  // LI: Decrypt using Web Crypto API
  const handleDecrypt = async () => {
    try {
      setLoading(true);
      setError("");
      setDecrypted("");

      if (!privateKey.trim()) {
        throw new Error("Please enter a private key");
      }

      if (!encryptedPayload.trim()) {
        throw new Error("Please enter an encrypted payload");
      }

      // LI: Import RSA private key
      const privateKeyBuffer = pemToArrayBuffer(privateKey);
      const cryptoKey = await window.crypto.subtle.importKey(
        "pkcs8",
        privateKeyBuffer,
        {
          name: "RSA-OAEP",
          hash: "SHA-256",
        },
        false,
        ["decrypt"]
      );

      // LI: Decode base64 encrypted payload
      const encryptedBytes = Uint8Array.from(window.atob(encryptedPayload), c => c.charCodeAt(0));

      // LI: Decrypt
      const decryptedBuffer = await window.crypto.subtle.decrypt(
        {
          name: "RSA-OAEP",
        },
        cryptoKey,
        encryptedBytes
      );

      // LI: Convert to string
      const decryptedText = new TextDecoder().decode(decryptedBuffer);
      setDecrypted(decryptedText);
    } catch (err) {
      console.error("LI: Decryption error", err);
      setError(err instanceof Error ? err.message : "Decryption failed. Please check your private key and encrypted payload.");
    } finally {
      setLoading(false);
    }
  };

  // LI: Clear all fields
  const handleClear = () => {
    setPrivateKey("");
    setEncryptedPayload("");
    setDecrypted("");
    setError("");
  };

  return (
    <Container maxWidth="md" sx={{ mt: 4, mb: 4 }}>
      <Title title="LI Decryption Tool" />
      <Card>
        <CardContent>
          <Typography variant="h5" sx={{ mb: 2 }}>
            RSA Decryption Tool
          </Typography>
          <Typography variant="body2" color="textSecondary" sx={{ mb: 3 }}>
            Decrypt recovery keys captured by the LI system. This tool works entirely in your browser
            and never sends your private key to any server.
          </Typography>

          {/* LI: Private Key Input */}
          <TextField
            fullWidth
            multiline
            rows={8}
            label="RSA Private Key (PKCS#8 PEM Format)"
            value={privateKey}
            onChange={(e) => setPrivateKey(e.target.value)}
            margin="normal"
            placeholder={`-----BEGIN PRIVATE KEY-----
MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQC...
-----END PRIVATE KEY-----`}
            sx={{
              fontFamily: "monospace",
              fontSize: "0.875rem",
            }}
          />

          {/* LI: Encrypted Payload Input */}
          <TextField
            fullWidth
            multiline
            rows={6}
            label="Encrypted Payload (Base64)"
            value={encryptedPayload}
            onChange={(e) => setEncryptedPayload(e.target.value)}
            margin="normal"
            placeholder="Base64 encoded encrypted recovery key from key_vault..."
            sx={{
              fontFamily: "monospace",
              fontSize: "0.875rem",
            }}
          />

          {/* LI: Action Buttons */}
          <Box sx={{ mt: 3, display: "flex", gap: 2 }}>
            <Button
              variant="contained"
              color="primary"
              onClick={handleDecrypt}
              disabled={loading}
            >
              {loading ? "Decrypting..." : "Decrypt"}
            </Button>
            <Button
              variant="outlined"
              onClick={handleClear}
              disabled={loading}
            >
              Clear
            </Button>
          </Box>

          {/* LI: Error Display */}
          {error && (
            <Alert severity="error" sx={{ mt: 3 }}>
              {error}
            </Alert>
          )}

          {/* LI: Decrypted Result */}
          {decrypted && (
            <Box sx={{ mt: 3 }}>
              <Alert severity="success" sx={{ mb: 2 }}>
                Decryption successful!
              </Alert>
              <TextField
                fullWidth
                multiline
                rows={4}
                label="Decrypted Recovery Key"
                value={decrypted}
                margin="normal"
                InputProps={{
                  readOnly: true,
                }}
                sx={{
                  fontFamily: "monospace",
                  fontSize: "0.875rem",
                  "& .MuiInputBase-input": {
                    backgroundColor: "#f5f5f5",
                  },
                }}
              />
              <Typography variant="caption" color="textSecondary" sx={{ mt: 1, display: "block" }}>
                This is the user's recovery key that can be used to restore their secure backup.
              </Typography>
            </Box>
          )}

          {/* LI: Instructions */}
          <Box sx={{ mt: 4 }}>
            <Typography variant="h6" sx={{ mb: 1 }}>
              Instructions
            </Typography>
            <Typography variant="body2" component="div">
              <ol>
                <li>Paste your RSA private key in PKCS#8 PEM format</li>
                <li>Paste the Base64 encoded encrypted payload from the key_vault database</li>
                <li>Click "Decrypt" to reveal the recovery key</li>
                <li>Use the recovery key to restore the user's secure backup if authorized</li>
              </ol>
            </Typography>
            <Alert severity="warning" sx={{ mt: 2 }}>
              <Typography variant="body2">
                <strong>Security Notice:</strong> This decryption tool should only be used by authorized personnel
                for lawful interception purposes. All usage should be logged and audited according to your organization's policies.
              </Typography>
            </Alert>
          </Box>
        </CardContent>
      </Card>
    </Container>
  );
};

export default DecryptionPage;
