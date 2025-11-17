#
# This file is licensed under the Affero General Public License (AGPL) version 3.
#
# Copyright 2020 Dirk Klimpel
# Copyright (C) 2023 New Vector, Ltd
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# See the GNU Affero General Public License for more details:
# <https://www.gnu.org/licenses/agpl-3.0.html>.
#
# Originally licensed under the Apache License, Version 2.0:
# <http://www.apache.org/licenses/LICENSE-2.0>.
#
# [This file includes modifications made by New Vector Limited]
#
#

import logging
from http import HTTPStatus
from typing import TYPE_CHECKING

from synapse.api.constants import Direction
from synapse.api.errors import Codes, SynapseError
from synapse.http.servlet import RestServlet, parse_enum, parse_integer, parse_string
from synapse.http.site import SynapseRequest
from synapse.rest.admin._base import admin_patterns, assert_requester_is_admin
from synapse.storage.databases.main.stats import UserSortOrder
from synapse.types import JsonDict

if TYPE_CHECKING:
    from synapse.server import HomeServer

logger = logging.getLogger(__name__)


class UserMediaStatisticsRestServlet(RestServlet):
    """
    Get statistics about uploaded media by users.
    """

    PATTERNS = admin_patterns("/statistics/users/media$")

    def __init__(self, hs: "HomeServer"):
        self.auth = hs.get_auth()
        self.store = hs.get_datastores().main

    async def on_GET(self, request: SynapseRequest) -> tuple[int, JsonDict]:
        await assert_requester_is_admin(self.auth, request)

        order_by = parse_string(
            request,
            "order_by",
            default=UserSortOrder.USER_ID.value,
            allowed_values=(
                UserSortOrder.MEDIA_LENGTH.value,
                UserSortOrder.MEDIA_COUNT.value,
                UserSortOrder.USER_ID.value,
                UserSortOrder.DISPLAYNAME.value,
            ),
        )

        start = parse_integer(request, "from", default=0)
        limit = parse_integer(request, "limit", default=100)
        from_ts = parse_integer(request, "from_ts", default=0)
        until_ts = parse_integer(request, "until_ts")

        if until_ts is not None:
            if until_ts <= from_ts:
                raise SynapseError(
                    HTTPStatus.BAD_REQUEST,
                    "Query parameter until_ts must be greater than from_ts.",
                    errcode=Codes.INVALID_PARAM,
                )

        search_term = parse_string(request, "search_term")
        if search_term == "":
            raise SynapseError(
                HTTPStatus.BAD_REQUEST,
                "Query parameter search_term cannot be an empty string.",
                errcode=Codes.INVALID_PARAM,
            )

        direction = parse_enum(request, "dir", Direction, default=Direction.FORWARDS)

        users_media, total = await self.store.get_users_media_usage_paginate(
            start, limit, from_ts, until_ts, order_by, direction, search_term
        )
        ret = {
            "users": [
                {
                    "user_id": r[0],
                    "displayname": r[1],
                    "media_count": r[2],
                    "media_length": r[3],
                }
                for r in users_media
            ],
            "total": total,
        }
        if (start + limit) < total:
            ret["next_token"] = start + len(users_media)

        return HTTPStatus.OK, ret


class LargestRoomsStatistics(RestServlet):
    """Get the largest rooms by database size.

    Only works when using PostgreSQL.
    """

    PATTERNS = admin_patterns("/statistics/database/rooms$")

    def __init__(self, hs: "HomeServer"):
        self.auth = hs.get_auth()
        self.stats_controller = hs.get_storage_controllers().stats

    async def on_GET(self, request: SynapseRequest) -> tuple[int, JsonDict]:
        await assert_requester_is_admin(self.auth, request)

        room_sizes = await self.stats_controller.get_room_db_size_estimate()

        return HTTPStatus.OK, {
            "rooms": [
                {"room_id": room_id, "estimated_size": size}
                for room_id, size in room_sizes
            ]
        }


# LI: Statistics endpoint for today's activity
class LIStatisticsTodayRestServlet(RestServlet):
    """
    LI: Get today's statistics (messages, active users, rooms created).
    Used by synapse-admin statistics dashboard.
    """

    PATTERNS = admin_patterns("/statistics/li/today$")

    def __init__(self, hs: "HomeServer"):
        self.auth = hs.get_auth()
        self.store = hs.get_datastores().main

    async def on_GET(self, request: SynapseRequest) -> tuple[int, JsonDict]:
        # LI: Verify admin access
        await assert_requester_is_admin(self.auth, request)

        # LI: Get today's timestamp range
        from datetime import datetime, timezone
        today = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
        today_ts_ms = int(today.timestamp() * 1000)

        # LI: Count messages sent today
        messages_sql = """
            SELECT COUNT(*) FROM events
            WHERE type = 'm.room.message'
            AND origin_server_ts >= ?
        """
        messages_count = await self.store.db_pool.simple_select_one_onecol(
            table="events",
            keyvalues={},
            retcol="COUNT(*)",
            desc="li_count_messages_today",
            allow_none=False,
        )

        # LI: Count active users today (users who sent events)
        active_users_sql = """
            SELECT COUNT(DISTINCT sender) FROM events
            WHERE origin_server_ts >= ?
        """
        active_users_rows = await self.store.db_pool.execute(
            "li_count_active_users_today",
            active_users_sql,
            today_ts_ms,
        )
        active_users = active_users_rows[0][0] if active_users_rows else 0

        # LI: Count rooms created today
        rooms_created_sql = """
            SELECT COUNT(*) FROM events
            WHERE type = 'm.room.create'
            AND origin_server_ts >= ?
        """
        rooms_created_rows = await self.store.db_pool.execute(
            "li_count_rooms_created_today",
            rooms_created_sql,
            today_ts_ms,
        )
        rooms_created = rooms_created_rows[0][0] if rooms_created_rows else 0

        logger.info(f"LI: Today's stats - messages: {messages_count}, active_users: {active_users}, rooms_created: {rooms_created}")

        return HTTPStatus.OK, {
            "messages": messages_count,
            "active_users": active_users,
            "rooms_created": rooms_created,
            "date": today.isoformat(),
        }


# LI: Historical statistics endpoint
class LIStatisticsHistoricalRestServlet(RestServlet):
    """
    LI: Get historical statistics for the last N days.
    Used by synapse-admin statistics dashboard for charts.
    """

    PATTERNS = admin_patterns("/statistics/li/historical$")

    def __init__(self, hs: "HomeServer"):
        self.auth = hs.get_auth()
        self.store = hs.get_datastores().main

    async def on_GET(self, request: SynapseRequest) -> tuple[int, JsonDict]:
        # LI: Verify admin access
        await assert_requester_is_admin(self.auth, request)

        # LI: Get number of days from query parameter (default 30)
        days = parse_integer(request, "days", default=30)
        if days > 365:
            raise SynapseError(
                HTTPStatus.BAD_REQUEST,
                "Cannot request more than 365 days of history",
                Codes.INVALID_PARAM,
            )

        # LI: Query historical data grouped by date
        # This query groups events by date and counts them
        historical_sql = """
            SELECT
                DATE(to_timestamp(origin_server_ts / 1000)) as date,
                COUNT(CASE WHEN type = 'm.room.message' THEN 1 END) as messages,
                COUNT(DISTINCT CASE WHEN type = 'm.room.message' THEN sender END) as active_users,
                COUNT(CASE WHEN type = 'm.room.create' THEN 1 END) as rooms_created
            FROM events
            WHERE origin_server_ts >= extract(epoch from (CURRENT_DATE - INTERVAL '%s days')) * 1000
            GROUP BY date
            ORDER BY date DESC
            LIMIT ?
        """ % days

        rows = await self.store.db_pool.execute(
            "li_get_historical_statistics",
            historical_sql,
            days,
        )

        historical_data = []
        for row in rows:
            date, messages, active_users, rooms_created = row
            historical_data.append({
                "date": str(date),
                "messages": messages or 0,
                "active_users": active_users or 0,
                "rooms_created": rooms_created or 0,
            })

        logger.info(f"LI: Returning {len(historical_data)} days of historical statistics")

        return HTTPStatus.OK, {
            "data": historical_data,
            "days": days,
        }


# LI: Top rooms statistics
class LIStatisticsTopRoomsRestServlet(RestServlet):
    """
    LI: Get top N most active rooms by message count.
    Used by synapse-admin statistics dashboard.
    """

    PATTERNS = admin_patterns("/statistics/li/top_rooms$")

    def __init__(self, hs: "HomeServer"):
        self.auth = hs.get_auth()
        self.store = hs.get_datastores().main

    async def on_GET(self, request: SynapseRequest) -> tuple[int, JsonDict]:
        # LI: Verify admin access
        await assert_requester_is_admin(self.auth, request)

        # LI: Get limit from query parameter (default 10)
        limit = parse_integer(request, "limit", default=10)
        if limit > 100:
            raise SynapseError(
                HTTPStatus.BAD_REQUEST,
                "Limit cannot exceed 100",
                Codes.INVALID_PARAM,
            )

        # LI: Get time range (default last 7 days)
        days = parse_integer(request, "days", default=7)

        # LI: Query top rooms by message count
        top_rooms_sql = """
            SELECT
                e.room_id,
                COUNT(*) as message_count,
                COUNT(DISTINCT e.sender) as unique_senders,
                r.name,
                r.canonical_alias
            FROM events e
            LEFT JOIN room_stats_state r ON e.room_id = r.room_id
            WHERE e.type = 'm.room.message'
            AND e.origin_server_ts >= extract(epoch from (CURRENT_DATE - INTERVAL '%s days')) * 1000
            GROUP BY e.room_id, r.name, r.canonical_alias
            ORDER BY message_count DESC
            LIMIT ?
        """ % days

        rows = await self.store.db_pool.execute(
            "li_get_top_rooms",
            top_rooms_sql,
            limit,
        )

        top_rooms = []
        for row in rows:
            room_id, message_count, unique_senders, name, canonical_alias = row
            top_rooms.append({
                "room_id": room_id,
                "message_count": message_count,
                "unique_senders": unique_senders,
                "name": name or canonical_alias or room_id,
            })

        logger.info(f"LI: Returning top {len(top_rooms)} rooms")

        return HTTPStatus.OK, {
            "rooms": top_rooms,
            "limit": limit,
            "days": days,
        }
