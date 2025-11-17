/*
Copyright 2024 New Vector Ltd.

SPDX-License-Identifier: AGPL-3.0-only OR GPL-3.0-only OR LicenseRef-Element-Commercial
Please see LICENSE files in the repository root for full details.
*/

// LI: Store for fetching and managing redacted (deleted) events
// This store is ONLY used in element-web-li to display deleted message content

import { type MatrixClient, type MatrixEvent } from "matrix-js-sdk/src/matrix";
import { logger } from "matrix-js-sdk/src/logger";

interface RedactedEventData {
    event_id: string;
    room_id: string;
    sender: string;
    origin_server_ts: number;
    type: string;
    content: any; // Original content before redaction
    redacted_by: string;
    redacted_at: number;
}

export class LIRedactedEventsStore {
    private static instance: LIRedactedEventsStore;
    private redactedEventsCache: Map<string, RedactedEventData[]> = new Map(); // roomId -> events
    private fetchPromises: Map<string, Promise<RedactedEventData[]>> = new Map(); // Prevent duplicate fetches
    private matrixClient: MatrixClient | null = null;

    public static get sharedInstance(): LIRedactedEventsStore {
        if (!LIRedactedEventsStore.instance) {
            LIRedactedEventsStore.instance = new LIRedactedEventsStore();
        }
        return LIRedactedEventsStore.instance;
    }

    public setMatrixClient(client: MatrixClient | null): void {
        this.matrixClient = client;
        if (!client) {
            this.redactedEventsCache.clear();
            this.fetchPromises.clear();
        }
    }

    /**
     * LI: Fetch redacted events for a specific room from Synapse.
     * Uses custom endpoint that returns original content for redacted events.
     *
     * @param roomId The room ID to fetch redacted events for
     * @returns Array of redacted events with original content
     */
    public async getRedactedEventsForRoom(roomId: string): Promise<RedactedEventData[]> {
        if (!this.matrixClient) {
            logger.warn("LI: Cannot fetch redacted events - no matrix client");
            return [];
        }

        // Return cached data if available
        const cached = this.redactedEventsCache.get(roomId);
        if (cached) {
            return cached;
        }

        // Return existing fetch promise if already fetching
        const existingFetch = this.fetchPromises.get(roomId);
        if (existingFetch) {
            return existingFetch;
        }

        // Start new fetch
        const fetchPromise = this.fetchRedactedEvents(roomId);
        this.fetchPromises.set(roomId, fetchPromise);

        try {
            const events = await fetchPromise;
            this.redactedEventsCache.set(roomId, events);
            return events;
        } finally {
            this.fetchPromises.delete(roomId);
        }
    }

    /**
     * LI: Fetch redacted events from Synapse's LI endpoint.
     * This endpoint requires authentication and returns redacted events with original content.
     */
    private async fetchRedactedEvents(roomId: string): Promise<RedactedEventData[]> {
        if (!this.matrixClient) {
            return [];
        }

        try {
            const url = `${this.matrixClient.getHomeserverUrl()}/_synapse/admin/v1/rooms/${encodeURIComponent(roomId)}/redacted_events`;

            logger.info(`LI: Fetching redacted events for room ${roomId}`);

            const response = await fetch(url, {
                method: "GET",
                headers: {
                    "Authorization": `Bearer ${this.matrixClient.getAccessToken()}`,
                    "Content-Type": "application/json",
                },
            });

            if (!response.ok) {
                // LI: If endpoint doesn't exist or user lacks permissions, fail silently
                if (response.status === 404 || response.status === 403) {
                    logger.warn(`LI: Redacted events endpoint not available or unauthorized (${response.status})`);
                    return [];
                }
                throw new Error(`HTTP ${response.status}: ${response.statusText}`);
            }

            const data = await response.json();
            const events: RedactedEventData[] = data.redacted_events || [];

            logger.info(`LI: Fetched ${events.length} redacted events for room ${roomId}`);
            return events;
        } catch (error) {
            logger.error("LI: Failed to fetch redacted events", error);
            return [];
        }
    }

    /**
     * LI: Check if an event is a redacted event that we have original content for.
     *
     * @param eventId The event ID to check
     * @param roomId The room ID
     * @returns The original event data if found, null otherwise
     */
    public getRedactedEventContent(eventId: string, roomId: string): RedactedEventData | null {
        const roomEvents = this.redactedEventsCache.get(roomId);
        if (!roomEvents) {
            return null;
        }

        const event = roomEvents.find((e) => e.event_id === eventId);
        return event || null;
    }

    /**
     * LI: Invalidate cache for a specific room.
     * Call this when new redactions occur to refresh the data.
     *
     * @param roomId The room ID to invalidate
     */
    public invalidateRoom(roomId: string): void {
        this.redactedEventsCache.delete(roomId);
        logger.debug(`LI: Invalidated redacted events cache for room ${roomId}`);
    }

    /**
     * LI: Clear all cached redacted events.
     */
    public clearCache(): void {
        this.redactedEventsCache.clear();
        this.fetchPromises.clear();
        logger.debug("LI: Cleared all redacted events cache");
    }
}

export default LIRedactedEventsStore.sharedInstance;
