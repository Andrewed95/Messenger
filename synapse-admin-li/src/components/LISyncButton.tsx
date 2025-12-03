// LI: Sync Button Component
// Provides a button in the AppBar to trigger and monitor database sync
// from synapse-admin-li to synapse-li.
//
// Per CLAUDE.md section 3.3:
// - Manual sync trigger available from synapse-admin-li
// - At most one sync process runs at any time (server-side lock)

import { useCallback, useEffect, useState } from "react";

import SyncIcon from "@mui/icons-material/Sync";
import { CircularProgress, IconButton, Tooltip } from "@mui/material";
import { fetchUtils, useNotify } from "react-admin";

import storage from "../storage";

// Sync status from the API
interface SyncStatus {
  is_running: boolean;
  last_sync_at: string | null;
  last_sync_status: "success" | "failed" | "never";
  last_dump_size_mb: number | null;
  last_duration_seconds: number | null;
  last_error: string | null;
  total_syncs: number;
  failed_syncs: number;
}

// API response for trigger
interface TriggerResponse {
  started: boolean;
  is_running?: boolean;
  message?: string;
  error?: string;
  stack_trace?: string;
}

// Helper to make authenticated API calls
const apiClient = (url: string, options: RequestInit = {}) => {
  const token = storage.getItem("access_token");
  if (token) {
    options.headers = {
      ...options.headers,
      Authorization: `Bearer ${token}`,
    };
  }
  return fetchUtils.fetchJson(url, options);
};

/**
 * LI: Sync Button for AppBar
 *
 * Shows a sync icon that:
 * - Displays "Sync" tooltip when idle
 * - Displays "Syncing..." tooltip and spinner when running
 * - Is disabled during sync
 * - Polls status every 60 seconds when sync is running
 * - Shows notification on completion or error
 */
export const LISyncButton = () => {
  const notify = useNotify();
  const [isRunning, setIsRunning] = useState(false);
  const [isLoading, setIsLoading] = useState(false);

  // Get the base URL for API calls
  const getBaseUrl = useCallback(() => {
    return storage.getItem("base_url") || "";
  }, []);

  // Fetch current sync status from synapse-li
  const fetchSyncStatus = useCallback(async (): Promise<SyncStatus | null> => {
    const baseUrl = getBaseUrl();
    if (!baseUrl) return null;

    try {
      const response = await apiClient(
        `${baseUrl}/_synapse/admin/v1/li/sync/status`
      );
      return response.json as SyncStatus;
    } catch (error) {
      console.error("LI: Failed to fetch sync status", error);
      return null;
    }
  }, [getBaseUrl]);

  // Trigger a new sync
  const triggerSync = useCallback(async () => {
    const baseUrl = getBaseUrl();
    if (!baseUrl) {
      notify("Not connected to homeserver", { type: "error" });
      return;
    }

    setIsLoading(true);

    try {
      const response = await apiClient(
        `${baseUrl}/_synapse/admin/v1/li/sync/trigger`,
        { method: "POST" }
      );
      const data = response.json as TriggerResponse;

      if (data.started) {
        setIsRunning(true);
        notify("Database sync started", { type: "info" });
      } else if (data.is_running) {
        setIsRunning(true);
        notify("Sync is already in progress", { type: "warning" });
      } else if (data.error) {
        notify(`Failed to start sync: ${data.error}`, { type: "error" });
        if (data.stack_trace) {
          console.error("LI: Sync error stack trace:", data.stack_trace);
        }
      }
    } catch (error: unknown) {
      const errorMessage =
        error instanceof Error ? error.message : "Unknown error";
      notify(`Failed to trigger sync: ${errorMessage}`, { type: "error" });
      console.error("LI: Failed to trigger sync", error);
    } finally {
      setIsLoading(false);
    }
  }, [getBaseUrl, notify]);

  // Poll sync status when running
  useEffect(() => {
    if (!isRunning) return;

    let isMounted = true;
    let hasNotified = false;

    const checkStatus = async () => {
      const status = await fetchSyncStatus();
      if (!isMounted || !status) return;

      // Check if sync has completed
      if (!status.is_running) {
        setIsRunning(false);

        // Only notify once per sync completion
        if (!hasNotified) {
          hasNotified = true;

          if (status.last_sync_status === "success") {
            const duration = status.last_duration_seconds
              ? `${status.last_duration_seconds.toFixed(1)}s`
              : "";
            const size = status.last_dump_size_mb
              ? `${status.last_dump_size_mb.toFixed(1)}MB`
              : "";
            const details = [duration, size].filter(Boolean).join(", ");
            notify(`Database sync completed successfully${details ? ` (${details})` : ""}`, {
              type: "success",
            });
          } else if (status.last_sync_status === "failed") {
            const errorMsg = status.last_error || "Unknown error";
            notify(`Database sync failed: ${errorMsg}`, { type: "error" });
          }
        }
      } else {
        // Still running, continue polling (every 60 seconds)
        setTimeout(checkStatus, 60000);
      }
    };

    // Start polling
    const pollTimer = setTimeout(checkStatus, 1000);

    return () => {
      isMounted = false;
      clearTimeout(pollTimer);
    };
  }, [isRunning, fetchSyncStatus, notify]);

  // Check initial sync status on mount
  useEffect(() => {
    const checkInitialStatus = async () => {
      const status = await fetchSyncStatus();
      if (status?.is_running) {
        setIsRunning(true);
      }
    };
    checkInitialStatus();
  }, [fetchSyncStatus]);

  // Handle button click
  const handleClick = () => {
    if (!isRunning && !isLoading) {
      triggerSync();
    }
  };

  const tooltipText = isRunning ? "Syncing..." : "Sync";
  const isDisabled = isRunning || isLoading;

  return (
    <Tooltip title={tooltipText}>
      <span>
        <IconButton
          color="inherit"
          onClick={handleClick}
          disabled={isDisabled}
          aria-label={tooltipText}
          sx={{
            // Spin animation when syncing
            "& .MuiSvgIcon-root": isRunning
              ? {
                  animation: "spin 1.5s linear infinite",
                  "@keyframes spin": {
                    "0%": { transform: "rotate(0deg)" },
                    "100%": { transform: "rotate(360deg)" },
                  },
                }
              : {},
          }}
        >
          {isLoading ? (
            <CircularProgress size={24} color="inherit" />
          ) : (
            <SyncIcon />
          )}
        </IconButton>
      </span>
    </Tooltip>
  );
};

export default LISyncButton;
