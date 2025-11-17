from django.db import models
from django.utils import timezone
import hashlib
import logging

logger = logging.getLogger(__name__)


class User(models.Model):
    """User record for key storage (matches Synapse username)."""
    username = models.CharField(max_length=255, unique=True, db_index=True)
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        db_table = 'secret_user'
        indexes = [
            models.Index(fields=['username']),
        ]

    def __str__(self):
        return self.username


class EncryptedKey(models.Model):
    """
    Stores encrypted recovery key for a user.

    - Never delete records (full history preserved)
    - Deduplication via payload_hash (only latest checked)
    - Admin retrieves latest key for impersonation

    Note: We store the RECOVERY KEY (not passphrase).
    The passphrase is converted to recovery key via PBKDF2 in the client.
    The recovery key is the actual AES-256 encryption key.
    """
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='keys')
    encrypted_payload = models.TextField()  # RSA-encrypted recovery key
    payload_hash = models.CharField(max_length=64, db_index=True)  # SHA256 hash for deduplication
    created_at = models.DateTimeField(default=timezone.now, db_index=True)

    class Meta:
        db_table = 'secret_encrypted_key'
        indexes = [
            models.Index(fields=['user', '-created_at']),  # For latest key retrieval
            models.Index(fields=['payload_hash']),  # For deduplication check
        ]
        ordering = ['-created_at']  # Latest first

    def save(self, *args, **kwargs):
        # Auto-calculate hash if not provided
        if not self.payload_hash:
            self.payload_hash = hashlib.sha256(self.encrypted_payload.encode()).hexdigest()

        # LI: Log key storage for audit trail
        logger.info(
            f"LI: Storing encrypted key for user {self.user.username}, "
            f"hash={self.payload_hash[:16]}"
        )

        super().save(*args, **kwargs)

    def __str__(self):
        return f"{self.user.username} ({self.created_at})"
