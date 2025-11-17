#!/bin/bash
# LI: Sync media files from main MinIO to hidden MinIO using rclone
#
# This script synchronizes media files from the main instance's MinIO storage
# to the hidden instance's MinIO storage. It uses rclone for efficient
# one-way synchronization.
#
# Prerequisites:
# - rclone must be installed and configured
# - /etc/rclone/rclone.conf must exist with main-s3 and hidden-s3 remotes
#
# Usage:
#   ./sync_media.sh [--since TIMESTAMP]

set -e

# Configuration
MAIN_REMOTE="main-s3"
HIDDEN_REMOTE="hidden-s3"
BUCKET="synapse-media"
LOG_DIR="/var/log/synapse-li"
LOG_FILE="${LOG_DIR}/media-sync.log"
RCLONE_CONFIG="/etc/rclone/rclone.conf"

# Create log directory if it doesn't exist
mkdir -p "${LOG_DIR}"

# Parse command line arguments
MIN_AGE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --since)
            MIN_AGE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Log start
echo "LI: Starting media sync at $(date)" | tee -a "${LOG_FILE}"

# Build rclone command
RCLONE_CMD=(
    rclone sync
    "${MAIN_REMOTE}:${BUCKET}/"
    "${HIDDEN_REMOTE}:${BUCKET}/"
    --config "${RCLONE_CONFIG}"
    --log-file "${LOG_FILE}"
    --log-level INFO
    --transfers 4
    --checkers 8
    --contimeout 60s
    --timeout 300s
    --retries 3
    --low-level-retries 10
    --stats 1m
    --stats-file-name-length 0
    --update  # Only transfer files that are newer
)

# Add min-age filter if provided
if [ -n "${MIN_AGE}" ]; then
    RCLONE_CMD+=(--min-age "${MIN_AGE}")
    echo "LI: Syncing files modified since ${MIN_AGE}" | tee -a "${LOG_FILE}"
fi

# Execute rclone sync
if "${RCLONE_CMD[@]}"; then
    echo "LI: Media sync completed successfully at $(date)" | tee -a "${LOG_FILE}"
    exit 0
else
    echo "LI: Media sync failed at $(date)" | tee -a "${LOG_FILE}"
    exit 1
fi
