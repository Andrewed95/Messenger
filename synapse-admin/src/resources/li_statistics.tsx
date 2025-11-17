// LI: Statistics dashboard for monitoring system activity
import AssessmentIcon from "@mui/icons-material/Assessment";
import {
  Box,
  Card,
  CardContent,
  Grid,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Typography,
} from "@mui/material";
import { useEffect, useState } from "react";
import { ResourceProps, Title, useDataProvider } from "react-admin";

interface TodayStats {
  messages: number;
  active_users: number;
  rooms_created: number;
  date: string;
}

interface TopRoom {
  room_id: string;
  name: string;
  message_count: number;
  unique_senders: number;
}

interface HistoricalData {
  date: string;
  messages: number;
  active_users: number;
  rooms_created: number;
}

export const LIStatisticsList = () => {
  const dataProvider = useDataProvider();
  const [todayStats, setTodayStats] = useState<TodayStats | null>(null);
  const [topRooms, setTopRooms] = useState<TopRoom[]>([]);
  const [historical, setHistorical] = useState<HistoricalData[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const fetchData = async () => {
      try {
        setLoading(true);
        setError(null);

        // LI: Fetch today's statistics
        const baseUrl = localStorage.getItem("base_url");
        const token = localStorage.getItem("access_token");

        if (!baseUrl || !token) {
          throw new Error("Not authenticated");
        }

        // LI: Fetch today's stats
        const todayResponse = await fetch(
          `${baseUrl}/_synapse/admin/v1/statistics/li/today`,
          {
            headers: {
              Authorization: `Bearer ${token}`,
            },
          }
        );
        if (todayResponse.ok) {
          const todayData = await todayResponse.json();
          setTodayStats(todayData);
        }

        // LI: Fetch top rooms
        const topRoomsResponse = await fetch(
          `${baseUrl}/_synapse/admin/v1/statistics/li/top_rooms?limit=10&days=7`,
          {
            headers: {
              Authorization: `Bearer ${token}`,
            },
          }
        );
        if (topRoomsResponse.ok) {
          const topRoomsData = await topRoomsResponse.json();
          setTopRooms(topRoomsData.rooms || []);
        }

        // LI: Fetch historical data
        const historicalResponse = await fetch(
          `${baseUrl}/_synapse/admin/v1/statistics/li/historical?days=7`,
          {
            headers: {
              Authorization: `Bearer ${token}`,
            },
          }
        );
        if (historicalResponse.ok) {
          const historicalData = await historicalResponse.json();
          setHistorical(historicalData.data || []);
        }
      } catch (err) {
        console.error("LI: Failed to fetch statistics", err);
        setError(err instanceof Error ? err.message : "Failed to fetch statistics");
      } finally {
        setLoading(false);
      }
    };

    fetchData();
  }, [dataProvider]);

  if (loading) {
    return (
      <Box sx={{ p: 3 }}>
        <Typography>Loading statistics...</Typography>
      </Box>
    );
  }

  if (error) {
    return (
      <Box sx={{ p: 3 }}>
        <Typography color="error">Error: {error}</Typography>
      </Box>
    );
  }

  return (
    <Box sx={{ p: 3 }}>
      <Title title="LI Statistics Dashboard" />

      {/* LI: Today's Statistics */}
      <Grid container spacing={3} sx={{ mb: 4 }}>
        <Grid item xs={12} md={4}>
          <Card>
            <CardContent>
              <Typography variant="overline" color="textSecondary">
                Messages Today
              </Typography>
              <Typography variant="h3" sx={{ mt: 1 }}>
                {todayStats?.messages?.toLocaleString() || 0}
              </Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={4}>
          <Card>
            <CardContent>
              <Typography variant="overline" color="textSecondary">
                Active Users Today
              </Typography>
              <Typography variant="h3" sx={{ mt: 1 }}>
                {todayStats?.active_users?.toLocaleString() || 0}
              </Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={4}>
          <Card>
            <CardContent>
              <Typography variant="overline" color="textSecondary">
                Rooms Created Today
              </Typography>
              <Typography variant="h3" sx={{ mt: 1 }}>
                {todayStats?.rooms_created?.toLocaleString() || 0}
              </Typography>
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      {/* LI: Top 10 Most Active Rooms */}
      <Card sx={{ mb: 4 }}>
        <CardContent>
          <Typography variant="h6" sx={{ mb: 2 }}>
            Top 10 Most Active Rooms (Last 7 Days)
          </Typography>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Room Name</TableCell>
                <TableCell align="right">Messages</TableCell>
                <TableCell align="right">Unique Senders</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {topRooms.map((room) => (
                <TableRow key={room.room_id}>
                  <TableCell>
                    <Typography variant="body2" noWrap sx={{ maxWidth: 400 }}>
                      {room.name}
                    </Typography>
                    <Typography variant="caption" color="textSecondary" noWrap>
                      {room.room_id}
                    </Typography>
                  </TableCell>
                  <TableCell align="right">{room.message_count.toLocaleString()}</TableCell>
                  <TableCell align="right">{room.unique_senders}</TableCell>
                </TableRow>
              ))}
              {topRooms.length === 0 && (
                <TableRow>
                  <TableCell colSpan={3} align="center">
                    <Typography color="textSecondary">No data available</Typography>
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      {/* LI: Historical Data (Last 7 Days) */}
      <Card>
        <CardContent>
          <Typography variant="h6" sx={{ mb: 2 }}>
            Activity - Last 7 Days
          </Typography>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Date</TableCell>
                <TableCell align="right">Messages</TableCell>
                <TableCell align="right">Active Users</TableCell>
                <TableCell align="right">Rooms Created</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {historical.map((day) => (
                <TableRow key={day.date}>
                  <TableCell>{day.date}</TableCell>
                  <TableCell align="right">{day.messages.toLocaleString()}</TableCell>
                  <TableCell align="right">{day.active_users.toLocaleString()}</TableCell>
                  <TableCell align="right">{day.rooms_created}</TableCell>
                </TableRow>
              ))}
              {historical.length === 0 && (
                <TableRow>
                  <TableCell colSpan={4} align="center">
                    <Typography color="textSecondary">No historical data available</Typography>
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </Box>
  );
};

const resource: ResourceProps = {
  name: "li_statistics",
  icon: AssessmentIcon,
  list: LIStatisticsList,
};

export default resource;
