from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework import status
from .models import User, EncryptedKey
import hashlib
import logging

logger = logging.getLogger(__name__)


class StoreKeyView(APIView):
    """
    API endpoint to store encrypted recovery key.

    Called by Synapse proxy endpoint (authenticated).
    Request format:
    {
        "username": "@user:server.com",
        "encrypted_payload": "Base64-encoded RSA-encrypted recovery key"
    }

    Deduplication logic:
    - Get latest key for this user
    - If hash matches incoming payload, skip (duplicate)
    - Otherwise, create new record (never delete old ones)
    """

    def post(self, request):
        # Extract data
        username = request.data.get('username')
        encrypted_payload = request.data.get('encrypted_payload')

        # LI: Log incoming request (audit trail)
        logger.info(f"LI: Received key storage request for user {username}")

        # Validate
        if not all([username, encrypted_payload]):
            logger.warning(f"LI: Missing required fields in request for {username}")
            return Response(
                {'error': 'Missing required fields'},
                status=status.HTTP_400_BAD_REQUEST
            )

        # Calculate hash
        payload_hash = hashlib.sha256(encrypted_payload.encode()).hexdigest()

        # Get or create user
        user, created = User.objects.get_or_create(username=username)

        if created:
            logger.info(f"LI: Created new user record for {username}")

        # Check if latest key matches (deduplication)
        latest_key = EncryptedKey.objects.filter(user=user).first()  # Ordered by -created_at

        if latest_key and latest_key.payload_hash == payload_hash:
            # Duplicate - no need to store
            logger.info(f"LI: Duplicate key for {username}, skipping storage")
            return Response({
                'status': 'skipped',
                'reason': 'Duplicate key (matches latest record)',
                'existing_key_id': latest_key.id
            }, status=status.HTTP_200_OK)

        # Create new record
        encrypted_key = EncryptedKey.objects.create(
            user=user,
            encrypted_payload=encrypted_payload,
            payload_hash=payload_hash
        )

        logger.info(
            f"LI: Successfully stored new key for {username}, "
            f"key_id={encrypted_key.id}"
        )

        return Response({
            'status': 'stored',
            'key_id': encrypted_key.id,
            'username': username,
            'created_at': encrypted_key.created_at.isoformat()
        }, status=status.HTTP_201_CREATED)
