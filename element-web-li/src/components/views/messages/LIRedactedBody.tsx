/*
Copyright 2024 New Vector Ltd.

SPDX-License-Identifier: AGPL-3.0-only OR GPL-3.0-only OR LicenseRef-Element-Commercial
Please see LICENSE files in the repository root for full details.
*/

// LI: Component for displaying deleted messages with their original content
// This component is ONLY used in element-web-li to show what was deleted

import React, { useContext, useEffect, useState, type JSX } from "react";
import { type MatrixClient, type MatrixEvent, EventType, MsgType } from "matrix-js-sdk/src/matrix";
import classNames from "classnames";

import { _t } from "../../../languageHandler";
import MatrixClientContext from "../../../contexts/MatrixClientContext";
import { formatFullDate } from "../../../DateUtils";
import SettingsStore from "../../../settings/SettingsStore";
import { type IBodyProps } from "./IBodyProps";
import { LIRedactedEventsStore } from "../../../stores/LIRedactedEvents";
import { renderTile } from "../../../events/EventTileFactory";
import RedactedBody from "./RedactedBody";

/**
 * LI: Component that displays deleted messages with their original content.
 * Shows a visual indication (light red background) that the message was deleted.
 */
const LIRedactedBody = ({ mxEvent, ref }: IBodyProps): JSX.Element => {
    const cli: MatrixClient = useContext(MatrixClientContext);
    const [originalContent, setOriginalContent] = useState<any | null>(null);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        // LI: Fetch the original content for this redacted event
        const fetchOriginalContent = async (): Promise<void> => {
            const roomId = mxEvent.getRoomId();
            const eventId = mxEvent.getId();

            if (!roomId || !eventId) {
                setLoading(false);
                return;
            }

            try {
                // Get redacted event data from the LI store
                const redactedData = LIRedactedEventsStore.sharedInstance.getRedactedEventContent(eventId, roomId);

                if (redactedData && redactedData.content) {
                    setOriginalContent(redactedData.content);
                } else {
                    // Try fetching from server if not in cache
                    await LIRedactedEventsStore.sharedInstance.getRedactedEventsForRoom(roomId);
                    const retryData = LIRedactedEventsStore.sharedInstance.getRedactedEventContent(eventId, roomId);
                    if (retryData && retryData.content) {
                        setOriginalContent(retryData.content);
                    }
                }
            } catch (error) {
                console.warn("LI: Failed to fetch original content for redacted event", error);
            } finally {
                setLoading(false);
            }
        };

        fetchOriginalContent();
    }, [mxEvent, cli]);

    // LI: If we don't have the original content, fall back to default RedactedBody
    if (loading || !originalContent) {
        return <RedactedBody mxEvent={mxEvent} ref={ref} />;
    }

    // LI: Prepare redaction info for display
    const unsigned = mxEvent.getUnsigned();
    const redactedBecauseUserId = unsigned && unsigned.redacted_because && unsigned.redacted_because.sender;
    const room = cli.getRoom(mxEvent.getRoomId());
    const sender = room && redactedBecauseUserId && room.getMember(redactedBecauseUserId);
    const redactorName = sender ? sender.name : redactedBecauseUserId;

    const showTwelveHour = SettingsStore.getValue("showTwelveHourTimestamps");
    const fullDate = unsigned.redacted_because
        ? formatFullDate(new Date(unsigned.redacted_because.origin_server_ts), showTwelveHour)
        : undefined;

    // LI: Render the original message content based on message type
    const renderOriginalContent = (): JSX.Element => {
        const msgType = originalContent.msgtype || MsgType.Text;

        // Handle different message types
        switch (msgType) {
            case MsgType.Text:
            case MsgType.Notice:
            case MsgType.Emote:
                return <span className="mx_LIRedactedBody_text">{originalContent.body || ""}</span>;

            case MsgType.Image:
                return (
                    <div className="mx_LIRedactedBody_media">
                        <span className="mx_LIRedactedBody_mediaIcon">🖼️</span>
                        <span className="mx_LIRedactedBody_mediaText">
                            {_t("Image")}: {originalContent.body || "Untitled"}
                        </span>
                    </div>
                );

            case MsgType.Video:
                return (
                    <div className="mx_LIRedactedBody_media">
                        <span className="mx_LIRedactedBody_mediaIcon">🎥</span>
                        <span className="mx_LIRedactedBody_mediaText">
                            {_t("Video")}: {originalContent.body || "Untitled"}
                        </span>
                    </div>
                );

            case MsgType.Audio:
                return (
                    <div className="mx_LIRedactedBody_media">
                        <span className="mx_LIRedactedBody_mediaIcon">🔊</span>
                        <span className="mx_LIRedactedBody_mediaText">
                            {_t("Audio")}: {originalContent.body || "Untitled"}
                        </span>
                    </div>
                );

            case MsgType.File:
                return (
                    <div className="mx_LIRedactedBody_media">
                        <span className="mx_LIRedactedBody_mediaIcon">📎</span>
                        <span className="mx_LIRedactedBody_mediaText">
                            {_t("File")}: {originalContent.body || "Untitled"}
                        </span>
                    </div>
                );

            case MsgType.Location:
                return (
                    <div className="mx_LIRedactedBody_media">
                        <span className="mx_LIRedactedBody_mediaIcon">📍</span>
                        <span className="mx_LIRedactedBody_mediaText">{_t("Location share")}</span>
                    </div>
                );

            default:
                return <span className="mx_LIRedactedBody_text">{originalContent.body || ""}</span>;
        }
    };

    const classes = classNames("mx_LIRedactedBody", {
        "mx_LIRedactedBody--hasContent": !!originalContent,
    });

    const titleText = fullDate
        ? _t("Deleted by {{name}} on {{date}}", { name: redactorName || "Unknown", date: fullDate })
        : _t("Deleted message");

    return (
        <div className={classes} ref={ref} title={titleText}>
            <div className="mx_LIRedactedBody_badge">
                <span className="mx_LIRedactedBody_deleteIcon">🗑️</span>
                <span className="mx_LIRedactedBody_label">{_t("Deleted")}</span>
            </div>
            <div className="mx_LIRedactedBody_content">{renderOriginalContent()}</div>
        </div>
    );
};

export default LIRedactedBody;
