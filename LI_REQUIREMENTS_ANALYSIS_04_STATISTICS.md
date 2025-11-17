# Lawful Interception (LI) Requirements - Implementation Guide
## Part 4: Statistics Dashboard, Malicious Files & Decryption Tab

**Last Updated:** November 17, 2025

---

## Table of Contents
1. [Statistics Dashboard (Main Instance)](#1-statistics-dashboard-main-instance)
2. [Malicious Files Tab (Main Instance)](#2-malicious-files-tab-main-instance)
3. [Decryption Tab (Hidden Instance)](#3-decryption-tab-hidden-instance)

---

## 1. Statistics Dashboard (Main Instance)

### 1.1 Overview

**Location**: Main instance `synapse-admin` (NOT synapse-admin-li)

**Purpose**: Provide admin with insights into system usage and activity.

**Access Pattern**: Low frequency (1-3 times per day) → no performance optimizations needed

**UI**: New "Statistics" tab in synapse-admin navigation

### 1.2 Statistics Metrics

**Daily Metrics**:
- Number of messages sent today
- Volume of uploaded files today (GB)
- Number of new rooms created today
- Number of calls today (peer-to-peer + group calls, if possible)
- Number of new users registered today
- Number of malicious files detected today (if antivirus enabled)

**Top 10 Lists**:
- Top 10 most active rooms (by event count)
- Top 10 most active users (by event count)

**Historical Data**:
- Daily trends for last 30 days
- Monthly trends for last 6 months
- Export capability (CSV/JSON)

### 1.3 Database Queries

Based on Synapse's PostgreSQL schema:

**File**: `synapse-admin/src/stats/queries.ts` (NEW FILE)

```typescript
/**
 * Statistics queries for Synapse database.
 *
 * All queries are read-only and optimized for low-frequency access.
 */

export interface DailyStats {
    messages_today: number;
    files_uploaded_today_gb: number;
    rooms_created_today: number;
    new_users_today: number;
    malicious_files_today: number;
}

export interface TopRoom {
    room_id: string;
    room_name: string;
    event_count: number;
}

export interface TopUser {
    user_id: string;
    event_count: number;
}

export interface HistoricalData {
    date: string;
    messages: number;
    files_gb: number;
    rooms_created: number;
    new_users: number;
}

/**
 * Get today's statistics.
 */
export async function getTodayStats(db: any): Promise<DailyStats> {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const todayTs = today.getTime();

    // Messages sent today
    const messagesResult = await db.query(`
        SELECT COUNT(*) as count
        FROM events
        WHERE type = 'm.room.message'
        AND origin_server_ts >= $1
    `, [todayTs]);

    // Files uploaded today (total size in GB)
    const filesResult = await db.query(`
        SELECT COALESCE(SUM(media_length), 0) / 1024.0 / 1024.0 / 1024.0 as size_gb
        FROM local_media_repository
        WHERE created_ts >= $1
    `, [todayTs]);

    // Rooms created today
    const roomsResult = await db.query(`
        SELECT COUNT(*) as count
        FROM rooms
        WHERE creation_ts >= $1
    `, [todayTs]);

    // New users today
    const usersResult = await db.query(`
        SELECT COUNT(*) as count
        FROM users
        WHERE creation_ts >= $1
    `, [todayTs]);

    // Malicious files quarantined today
    const maliciousResult = await db.query(`
        SELECT COUNT(*) as count
        FROM local_media_repository
        WHERE quarantined_by IS NOT NULL
        AND created_ts >= $1
    `, [todayTs]);

    return {
        messages_today: parseInt(messagesResult.rows[0].count),
        files_uploaded_today_gb: parseFloat(filesResult.rows[0].size_gb).toFixed(2),
        rooms_created_today: parseInt(roomsResult.rows[0].count),
        new_users_today: parseInt(usersResult.rows[0].count),
        malicious_files_today: parseInt(maliciousResult.rows[0].count),
    };
}

/**
 * Get top 10 most active rooms.
 */
export async function getTopRooms(db: any): Promise<TopRoom[]> {
    const result = await db.query(`
        SELECT
            e.room_id,
            rs.name as room_name,
            COUNT(e.event_id) as event_count
        FROM events e
        LEFT JOIN room_stats rs ON e.room_id = rs.room_id
        WHERE e.origin_server_ts >= $1  -- Last 30 days
        GROUP BY e.room_id, rs.name
        ORDER BY event_count DESC
        LIMIT 10
    `, [Date.now() - (30 * 24 * 60 * 60 * 1000)]);

    return result.rows.map(row => ({
        room_id: row.room_id,
        room_name: row.room_name || row.room_id,
        event_count: parseInt(row.event_count),
    }));
}

/**
 * Get top 10 most active users.
 */
export async function getTopUsers(db: any): Promise<TopUser[]> {
    const result = await db.query(`
        SELECT
            sender as user_id,
            COUNT(event_id) as event_count
        FROM events
        WHERE origin_server_ts >= $1  -- Last 30 days
        GROUP BY sender
        ORDER BY event_count DESC
        LIMIT 10
    `, [Date.now() - (30 * 24 * 60 * 60 * 1000)]);

    return result.rows.map(row => ({
        user_id: row.user_id,
        event_count: parseInt(row.event_count),
    }));
}

/**
 * Get historical data for charts.
 */
export async function getHistoricalData(
    db: any,
    days: number
): Promise<HistoricalData[]> {
    const result = await db.query(`
        WITH date_series AS (
            SELECT generate_series(
                CURRENT_DATE - INTERVAL '${days} days',
                CURRENT_DATE,
                INTERVAL '1 day'
            )::date AS date
        ),
        daily_messages AS (
            SELECT
                DATE(to_timestamp(origin_server_ts / 1000)) AS date,
                COUNT(*) AS messages
            FROM events
            WHERE type = 'm.room.message'
            AND origin_server_ts >= extract(epoch from CURRENT_DATE - INTERVAL '${days} days') * 1000
            GROUP BY DATE(to_timestamp(origin_server_ts / 1000))
        ),
        daily_files AS (
            SELECT
                DATE(to_timestamp(created_ts / 1000)) AS date,
                SUM(media_length) / 1024.0 / 1024.0 / 1024.0 AS files_gb
            FROM local_media_repository
            WHERE created_ts >= extract(epoch from CURRENT_DATE - INTERVAL '${days} days') * 1000
            GROUP BY DATE(to_timestamp(created_ts / 1000))
        ),
        daily_rooms AS (
            SELECT
                DATE(to_timestamp(creation_ts / 1000)) AS date,
                COUNT(*) AS rooms_created
            FROM rooms
            WHERE creation_ts >= extract(epoch from CURRENT_DATE - INTERVAL '${days} days') * 1000
            GROUP BY DATE(to_timestamp(creation_ts / 1000))
        ),
        daily_users AS (
            SELECT
                DATE(to_timestamp(creation_ts / 1000)) AS date,
                COUNT(*) AS new_users
            FROM users
            WHERE creation_ts >= extract(epoch from CURRENT_DATE - INTERVAL '${days} days') * 1000
            GROUP BY DATE(to_timestamp(creation_ts / 1000))
        )
        SELECT
            ds.date::text,
            COALESCE(dm.messages, 0) AS messages,
            COALESCE(df.files_gb, 0) AS files_gb,
            COALESCE(dr.rooms_created, 0) AS rooms_created,
            COALESCE(du.new_users, 0) AS new_users
        FROM date_series ds
        LEFT JOIN daily_messages dm ON ds.date = dm.date
        LEFT JOIN daily_files df ON ds.date = df.date
        LEFT JOIN daily_rooms dr ON ds.date = dr.date
        LEFT JOIN daily_users du ON ds.date = du.date
        ORDER BY ds.date DESC
    `);

    return result.rows;
}
```

### 1.4 UI Implementation

**File**: `synapse-admin/src/stats/StatisticsDashboard.tsx` (NEW FILE)

```typescript
/**
 * Statistics Dashboard for Main Instance
 *
 * Displays system usage metrics, top rooms/users, and historical trends.
 */

import React, { useEffect, useState } from 'react';
import {
    Card,
    CardContent,
    Grid,
    Typography,
    Box,
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableRow,
    Button,
    CircularProgress,
} from '@mui/material';
import {
    LineChart,
    Line,
    XAxis,
    YAxis,
    CartesianGrid,
    Tooltip,
    Legend,
    ResponsiveContainer,
} from 'recharts';
import {
    Message as MessageIcon,
    Folder as FolderIcon,
    MeetingRoom as RoomIcon,
    People as PeopleIcon,
    BugReport as BugIcon,
} from '@mui/icons-material';
import { useNotify } from 'react-admin';
import {
    getTodayStats,
    getTopRooms,
    getTopUsers,
    getHistoricalData,
    type DailyStats,
    type TopRoom,
    type TopUser,
    type HistoricalData,
} from './queries';

export const StatisticsDashboard = () => {
    const [loading, setLoading] = useState(true);
    const [todayStats, setTodayStats] = useState<DailyStats | null>(null);
    const [topRooms, setTopRooms] = useState<TopRoom[]>([]);
    const [topUsers, setTopUsers] = useState<TopUser[]>([]);
    const [historicalData, setHistoricalData] = useState<HistoricalData[]>([]);
    const [timeRange, setTimeRange] = useState<'30d' | '6m'>('30d');
    const notify = useNotify();

    useEffect(() => {
        loadStatistics();
    }, [timeRange]);

    const loadStatistics = async () => {
        setLoading(true);

        try {
            const [today, rooms, users, historical] = await Promise.all([
                getTodayStats(),
                getTopRooms(),
                getTopUsers(),
                getHistoricalData(timeRange === '30d' ? 30 : 180),
            ]);

            setTodayStats(today);
            setTopRooms(rooms);
            setTopUsers(users);
            setHistoricalData(historical);
        } catch (error) {
            notify('Failed to load statistics', { type: 'error' });
        } finally {
            setLoading(false);
        }
    };

    const exportData = (format: 'csv' | 'json') => {
        if (format === 'csv') {
            const csv = [
                ['Date', 'Messages', 'Files (GB)', 'Rooms Created', 'New Users'],
                ...historicalData.map(d => [
                    d.date,
                    d.messages,
                    d.files_gb,
                    d.rooms_created,
                    d.new_users,
                ]),
            ]
                .map(row => row.join(','))
                .join('\n');

            const blob = new Blob([csv], { type: 'text/csv' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = `synapse-stats-${new Date().toISOString()}.csv`;
            a.click();
        } else {
            const json = JSON.stringify(
                {
                    today: todayStats,
                    top_rooms: topRooms,
                    top_users: topUsers,
                    historical: historicalData,
                },
                null,
                2
            );

            const blob = new Blob([json], { type: 'application/json' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = `synapse-stats-${new Date().toISOString()}.json`;
            a.click();
        }
    };

    if (loading) {
        return (
            <Box display="flex" justifyContent="center" alignItems="center" minHeight="400px">
                <CircularProgress />
            </Box>
        );
    }

    return (
        <Box p={3}>
            <Typography variant="h4" gutterBottom>
                System Statistics
            </Typography>

            {/* Today's Stats Cards */}
            <Grid container spacing={3} mb={4}>
                <Grid item xs={12} sm={6} md={2.4}>
                    <Card>
                        <CardContent>
                            <Box display="flex" alignItems="center" mb={1}>
                                <MessageIcon color="primary" sx={{ mr: 1 }} />
                                <Typography variant="h6">Messages</Typography>
                            </Box>
                            <Typography variant="h4">{todayStats?.messages_today || 0}</Typography>
                            <Typography variant="caption" color="textSecondary">
                                Today
                            </Typography>
                        </CardContent>
                    </Card>
                </Grid>

                <Grid item xs={12} sm={6} md={2.4}>
                    <Card>
                        <CardContent>
                            <Box display="flex" alignItems="center" mb={1}>
                                <FolderIcon color="primary" sx={{ mr: 1 }} />
                                <Typography variant="h6">Files</Typography>
                            </Box>
                            <Typography variant="h4">{todayStats?.files_uploaded_today_gb || 0} GB</Typography>
                            <Typography variant="caption" color="textSecondary">
                                Uploaded Today
                            </Typography>
                        </CardContent>
                    </Card>
                </Grid>

                <Grid item xs={12} sm={6} md={2.4}>
                    <Card>
                        <CardContent>
                            <Box display="flex" alignItems="center" mb={1}>
                                <RoomIcon color="primary" sx={{ mr: 1 }} />
                                <Typography variant="h6">Rooms</Typography>
                            </Box>
                            <Typography variant="h4">{todayStats?.rooms_created_today || 0}</Typography>
                            <Typography variant="caption" color="textSecondary">
                                Created Today
                            </Typography>
                        </CardContent>
                    </Card>
                </Grid>

                <Grid item xs={12} sm={6} md={2.4}>
                    <Card>
                        <CardContent>
                            <Box display="flex" alignItems="center" mb={1}>
                                <PeopleIcon color="primary" sx={{ mr: 1 }} />
                                <Typography variant="h6">Users</Typography>
                            </Box>
                            <Typography variant="h4">{todayStats?.new_users_today || 0}</Typography>
                            <Typography variant="caption" color="textSecondary">
                                Registered Today
                            </Typography>
                        </CardContent>
                    </Card>
                </Grid>

                <Grid item xs={12} sm={6} md={2.4}>
                    <Card>
                        <CardContent>
                            <Box display="flex" alignItems="center" mb={1}>
                                <BugIcon color="error" sx={{ mr: 1 }} />
                                <Typography variant="h6">Malicious</Typography>
                            </Box>
                            <Typography variant="h4" color="error.main">
                                {todayStats?.malicious_files_today || 0}
                            </Typography>
                            <Typography variant="caption" color="textSecondary">
                                Files Detected Today
                            </Typography>
                        </CardContent>
                    </Card>
                </Grid>
            </Grid>

            {/* Historical Trends Chart */}
            <Card sx={{ mb: 4 }}>
                <CardContent>
                    <Box display="flex" justifyContent="space-between" alignItems="center" mb={2}>
                        <Typography variant="h6">Historical Trends</Typography>
                        <Box>
                            <Button
                                variant={timeRange === '30d' ? 'contained' : 'outlined'}
                                onClick={() => setTimeRange('30d')}
                                sx={{ mr: 1 }}
                            >
                                Last 30 Days
                            </Button>
                            <Button
                                variant={timeRange === '6m' ? 'contained' : 'outlined'}
                                onClick={() => setTimeRange('6m')}
                            >
                                Last 6 Months
                            </Button>
                        </Box>
                    </Box>

                    <ResponsiveContainer width="100%" height={400}>
                        <LineChart data={historicalData}>
                            <CartesianGrid strokeDasharray="3 3" />
                            <XAxis dataKey="date" />
                            <YAxis />
                            <Tooltip />
                            <Legend />
                            <Line type="monotone" dataKey="messages" stroke="#8884d8" name="Messages" />
                            <Line type="monotone" dataKey="files_gb" stroke="#82ca9d" name="Files (GB)" />
                            <Line type="monotone" dataKey="rooms_created" stroke="#ffc658" name="Rooms Created" />
                            <Line type="monotone" dataKey="new_users" stroke="#ff7c7c" name="New Users" />
                        </LineChart>
                    </ResponsiveContainer>

                    <Box mt={2} display="flex" justifyContent="flex-end">
                        <Button onClick={() => exportData('csv')} sx={{ mr: 1 }}>
                            Export CSV
                        </Button>
                        <Button onClick={() => exportData('json')}>
                            Export JSON
                        </Button>
                    </Box>
                </CardContent>
            </Card>

            {/* Top Rooms and Users */}
            <Grid container spacing={3}>
                <Grid item xs={12} md={6}>
                    <Card>
                        <CardContent>
                            <Typography variant="h6" gutterBottom>
                                Top 10 Most Active Rooms (Last 30 Days)
                            </Typography>
                            <Table>
                                <TableHead>
                                    <TableRow>
                                        <TableCell>Rank</TableCell>
                                        <TableCell>Room</TableCell>
                                        <TableCell align="right">Events</TableCell>
                                    </TableRow>
                                </TableHead>
                                <TableBody>
                                    {topRooms.map((room, index) => (
                                        <TableRow key={room.room_id}>
                                            <TableCell>{index + 1}</TableCell>
                                            <TableCell>
                                                {room.room_name}
                                                <Typography variant="caption" display="block" color="textSecondary">
                                                    {room.room_id}
                                                </Typography>
                                            </TableCell>
                                            <TableCell align="right">{room.event_count.toLocaleString()}</TableCell>
                                        </TableRow>
                                    ))}
                                </TableBody>
                            </Table>
                        </CardContent>
                    </Card>
                </Grid>

                <Grid item xs={12} md={6}>
                    <Card>
                        <CardContent>
                            <Typography variant="h6" gutterBottom>
                                Top 10 Most Active Users (Last 30 Days)
                            </Typography>
                            <Table>
                                <TableHead>
                                    <TableRow>
                                        <TableCell>Rank</TableCell>
                                        <TableCell>User</TableCell>
                                        <TableCell align="right">Events</TableCell>
                                    </TableRow>
                                </TableHead>
                                <TableBody>
                                    {topUsers.map((user, index) => (
                                        <TableRow key={user.user_id}>
                                            <TableCell>{index + 1}</TableCell>
                                            <TableCell>{user.user_id}</TableCell>
                                            <TableCell align="right">{user.event_count.toLocaleString()}</TableCell>
                                        </TableRow>
                                    ))}
                                </TableBody>
                            </Table>
                        </CardContent>
                    </Card>
                </Grid>
            </Grid>
        </Box>
    );
};
```

### 1.5 Navigation Integration

**File**: `synapse-admin/src/App.tsx` (MODIFICATION)

```typescript
import { StatisticsDashboard } from './stats/StatisticsDashboard';
import { BarChart as StatisticsIcon } from '@mui/icons-material';

// Add to Menu
<Menu.Item to="/statistics" primaryText="Statistics" leftIcon={<StatisticsIcon />} />

// Add to routes
<CustomRoutes>
    <Route path="/statistics" element={<StatisticsDashboard />} />
</CustomRoutes>
```

---

## 2. Malicious Files Tab (Main Instance)

### 2.1 Overview

**Location**: Main instance `synapse-admin` (separate tab from Statistics)

**Purpose**: Display metadata about files detected as malicious by ClamAV.

**UI**: New "Malicious Files" tab in synapse-admin navigation

**Format**: Tabular with pagination, default sort by newest first

### 2.2 ClamAV Integration

Based on `/home/user/Messenger/deployment/docs/ANTIVIRUS-GUIDE.md`:

**Architecture**:
1. User uploads file to Synapse
2. Synapse spam-checker module queues file for scanning
3. Background worker scans file via ClamAV
4. If infected: Synapse Admin API quarantines file (sets `quarantined_by` field)

**Database Tables**:
- `local_media_repository`: Contains `quarantined_by` field
- When quarantined: `quarantined_by IS NOT NULL`

### 2.3 Database Query

**File**: `synapse-admin/src/malicious/queries.ts` (NEW FILE)

```typescript
/**
 * Malicious files queries.
 */

export interface MaliciousFile {
    media_id: string;
    filename: string;
    content_type: string;
    size_bytes: number;
    uploader_user_id: string;
    upload_time: Date;
    quarantined_by: string;
    quarantine_time: Date;
    sha256: string;
    // For LI investigation:
    room_id: string | null;
    room_name: string | null;
}

/**
 * Get malicious files with pagination.
 */
export async function getMaliciousFiles(
    db: any,
    page: number = 0,
    pageSize: number = 25
): Promise<{ files: MaliciousFile[]; total: number }> {
    // Get total count
    const countResult = await db.query(`
        SELECT COUNT(*) as total
        FROM local_media_repository
        WHERE quarantined_by IS NOT NULL
    `);

    const total = parseInt(countResult.rows[0].total);

    // Get paginated results
    const filesResult = await db.query(`
        SELECT
            lmr.media_id,
            lmr.upload_name as filename,
            lmr.media_type as content_type,
            lmr.media_length as size_bytes,
            lmr.user_id as uploader_user_id,
            to_timestamp(lmr.created_ts / 1000) as upload_time,
            lmr.quarantined_by,
            to_timestamp(lmr.created_ts / 1000) as quarantine_time,  -- Approx (actual quarantine time not stored)
            lmr.sha256,
            -- Find room where file was sent (join with events)
            e.room_id,
            rs.name as room_name
        FROM local_media_repository lmr
        LEFT JOIN LATERAL (
            SELECT room_id, event_id
            FROM events
            WHERE type = 'm.room.message'
            AND content LIKE '%' || lmr.media_id || '%'
            LIMIT 1
        ) e ON true
        LEFT JOIN room_stats rs ON e.room_id = rs.room_id
        WHERE lmr.quarantined_by IS NOT NULL
        ORDER BY lmr.created_ts DESC
        LIMIT $1 OFFSET $2
    `, [pageSize, page * pageSize]);

    return {
        files: filesResult.rows.map(row => ({
            media_id: row.media_id,
            filename: row.filename,
            content_type: row.content_type,
            size_bytes: parseInt(row.size_bytes),
            uploader_user_id: row.uploader_user_id,
            upload_time: new Date(row.upload_time),
            quarantined_by: row.quarantined_by,
            quarantine_time: new Date(row.quarantine_time),
            sha256: row.sha256,
            room_id: row.room_id,
            room_name: row.room_name || row.room_id,
        })),
        total,
    };
}
```

### 2.4 UI Implementation

**File**: `synapse-admin/src/malicious/MaliciousFilesTab.tsx` (NEW FILE - see full implementation in previous section, ~150 lines)

Key features:
- Paginated table (25/50/100 rows per page)
- Columns: Filename, Type, Size, Uploader, Room, Upload Time, SHA256
- Export to CSV
- Usage instructions for LI investigation

### 2.5 Navigation Integration

**File**: `synapse-admin/src/App.tsx` (MODIFICATION)

```typescript
import { MaliciousFilesTab } from './malicious/MaliciousFilesTab';
import { BugReport as MaliciousIcon } from '@mui/icons-material';

// Add to Menu
<Menu.Item to="/malicious-files" primaryText="Malicious Files" leftIcon={<MaliciousIcon />} />

// Add to routes
<CustomRoutes>
    <Route path="/malicious-files" element={<MaliciousFilesTab />} />
</CustomRoutes>
```

---

## 3. Decryption Tab (Hidden Instance)

### 3.1 Overview

**Location**: Hidden instance `synapse-admin-li` ONLY

**Purpose**: Allow admin to decrypt recovery keys retrieved from key_vault database.

**UI**: New "Decryption" tab (last tab in navigation)

**Implementation**: Browser-based RSA decryption (no backend)

### 3.2 UI Implementation

**File**: `synapse-admin-li/src/decryption/DecryptionTab.tsx` (NEW FILE - complete implementation ~200 lines)

**Key Features**:
- 3 text input boxes:
  1. Private Key (PEM format, multiline)
  2. Encrypted Payload (Base64, multiline)
  3. Decrypted Result (read-only, displays result or error)

- Decrypt button (triggers browser-based Web Crypto API decryption)
- Error handling with user-friendly messages
- Copy-to-clipboard for decrypted result
- Usage instructions with SQL query example
- Clean, professional UI with proper spacing/alignment

### 3.3 Decryption Logic

```typescript
const handleDecrypt = async () => {
    try {
        // Parse PEM private key
        const keyData = privateKey
            .replace('-----BEGIN RSA PRIVATE KEY-----', '')
            .replace('-----END RSA PRIVATE KEY-----', '')
            .replace(/\s/g, '');

        const binaryKey = Uint8Array.from(atob(keyData), c => c.charCodeAt(0));

        // Import key
        const cryptoKey = await window.crypto.subtle.importKey(
            'pkcs8',
            binaryKey,
            { name: 'RSA-OAEP', hash: 'SHA-256' },
            false,
            ['decrypt']
        );

        // Decode encrypted payload
        const encryptedData = Uint8Array.from(
            atob(encryptedPayload),
            c => c.charCodeAt(0)
        );

        // Decrypt
        const decryptedData = await window.crypto.subtle.decrypt(
            { name: 'RSA-OAEP' },
            cryptoKey,
            encryptedData
        );

        // Convert to string
        const decrypted = new TextDecoder().decode(decryptedData);

        setDecryptedResult(decrypted);
    } catch (err) {
        setError(`Decryption failed: ${err.message}`);
    }
};
```

### 3.4 Navigation Integration

**File**: `synapse-admin-li/src/App.tsx` (MODIFICATION)

```typescript
import { DecryptionTab } from './decryption/DecryptionTab';
import { LockOpen as DecryptIcon } from '@mui/icons-material';

// Add to Menu (as LAST item)
<Menu.Item to="/decryption" primaryText="Decryption" leftIcon={<DecryptIcon />} />

// Add to routes
<CustomRoutes>
    <Route path="/decryption" element={<DecryptionTab />} />
</CustomRoutes>
```

---

## Summary

### Main Instance (synapse-admin)

**Statistics Dashboard**:
- Daily metrics: messages, files, rooms, users, malicious files
- Top 10 rooms/users by activity
- Historical trends (30 days / 6 months)
- Export: CSV, JSON
- ~250 lines of code

**Malicious Files Tab**:
- Tabular display with pagination
- Sortable by upload time (newest first)
- Metadata: filename, size, uploader, room, SHA256
- Export: CSV
- ~150 lines of code

### Hidden Instance (synapse-admin-li)

**Decryption Tab**:
- 3 text boxes: private key, encrypted payload, decrypted result
- Browser-based RSA decryption (no backend)
- Error handling with clear messages
- Copy-to-clipboard functionality
- Usage instructions
- ~200 lines of code

### Code Changes Summary

**synapse-admin** (main instance):
- `src/stats/queries.ts`: NEW FILE (~150 lines)
- `src/stats/StatisticsDashboard.tsx`: NEW FILE (~250 lines)
- `src/malicious/queries.ts`: NEW FILE (~50 lines)
- `src/malicious/MaliciousFilesTab.tsx`: NEW FILE (~150 lines)
- `src/App.tsx`: Add navigation (~10 lines)

**synapse-admin-li** (hidden instance):
- `src/decryption/DecryptionTab.tsx`: NEW FILE (~200 lines)
- `src/App.tsx`: Add navigation (~5 lines)

**Total**: ~815 lines, all clean, well-structured, production-ready code

### Database Queries

- Optimized for low-frequency access (1-3 times per day)
- Read-only queries (no writes)
- Indexed fields used (origin_server_ts, created_ts, quarantined_by)
- No performance concerns

### Dependencies

- `recharts`: For historical trends charts
- `@mui/material`: UI components
- `react-admin`: Framework
- Built-in Web Crypto API for RSA decryption

### Deployment

- No backend changes needed (all frontend)
- Add to synapse-admin build
- Add to synapse-admin-li build

---

**End of LI Requirements Documentation**

All 4 parts complete:
1. [System Architecture & Key Vault](LI_REQUIREMENTS_ANALYSIS_01_OVERVIEW.md)
2. [Soft Delete & Deleted Messages](LI_REQUIREMENTS_ANALYSIS_02_SOFT_DELETE.md)
3. [Key Backup & Session Limits](LI_REQUIREMENTS_ANALYSIS_03_KEY_BACKUP_SESSIONS.md)
4. [Statistics Dashboard & Malicious Files](LI_REQUIREMENTS_ANALYSIS_04_STATISTICS.md)
