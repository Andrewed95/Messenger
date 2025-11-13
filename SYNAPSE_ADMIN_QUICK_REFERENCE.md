# Synapse-Admin Quick Reference Guide

## File Locations Summary

```
/home/user/Messenger/synapse-admin/
├── src/
│   ├── App.tsx                           [MODIFY] Register new resources
│   ├── synapse/
│   │   └── dataProvider.ts               [MODIFY] Add resource mappings & types
│   ├── resources/
│   │   ├── user_media_statistics.tsx     [EXAMPLE] Simple stats resource
│   │   └── rooms.tsx                     [EXAMPLE] Complex resource with tabs
│   ├── components/
│   │   └── media.tsx                     [EXAMPLE] Custom components & buttons
│   └── i18n/
│       ├── en.ts                         [MODIFY] English translations
│       ├── de.ts, fr.ts, it.ts, ...     [MODIFY] Other languages
│       └── index.d.ts                    [MODIFY] Translation type definitions
```

---

## Statistics Features Currently Implemented

### 1. User Media Statistics
- **API Endpoint**: `/_synapse/admin/v1/statistics/users/media`
- **File**: `/src/resources/user_media_statistics.tsx`
- **Features**: List view with pagination, search, export, media deletion
- **Fields**: user_id, displayname, media_count, media_length

---

## Step-by-Step: Add New Statistics Endpoint

### Example: Server-Wide Statistics

#### 1. Data Provider (dataProvider.ts)

Find line ~392 and add before the closing brace:

```typescript
// Around line 400 in dataProvider.ts

interface ServerStatistic {
  timestamp: number;
  total_rooms: number;
  total_users: number;
  total_events: number;
  total_connections: number;
}

// In resourceMap (line ~228)
server_statistics: {
  path: "/_synapse/admin/v1/statistics",
  map: (stat: ServerStatistic) => ({
    ...stat,
    id: `${stat.timestamp}`,  // Create unique ID
  }),
  data: "statistics",           // Key containing array in response
  total: json => json.total,    // Extract total count
},
```

#### 2. Resource Component (resources/server_statistics.tsx)

Create new file:

```typescript
import EqualizerIcon from "@mui/icons-material/Equalizer";
import {
  Datagrid,
  List,
  ListProps,
  NumberField,
  ResourceProps,
  TextField,
} from "react-admin";

export const ServerStatsList = (props: ListProps) => (
  <List {...props}>
    <Datagrid rowClick={false}>
      <TextField source="timestamp" label="Time" />
      <NumberField source="total_rooms" label="Rooms" />
      <NumberField source="total_users" label="Users" />
      <NumberField source="total_events" label="Events" />
      <NumberField source="total_connections" label="Connections" />
    </Datagrid>
  </List>
);

const resource: ResourceProps = {
  name: "server_statistics",
  icon: EqualizerIcon,
  list: ServerStatsList,
};

export default resource;
```

#### 3. Register in App.tsx

Around line 20, add import:
```typescript
import serverStats from "./resources/server_statistics";
```

Around line 70, add resource:
```typescript
<Resource {...userMediaStats} />
<Resource {...serverStats} />  {/* NEW */}
<Resource {...reports} />
```

#### 4. Add Translations (en.ts)

Around line 326 (after user_media_statistics), add:

```typescript
server_statistics: {
  name: "Server Statistics",
  fields: {
    timestamp: "Timestamp",
    total_rooms: "Total Rooms",
    total_users: "Total Users",
    total_events: "Total Events",
    total_connections: "Connections",
  },
},
```

#### 5. Add to Type Definitions (i18n/index.d.ts)

Around line 335, add:

```typescript
server_statistics: {
  name: string;
  fields: {
    timestamp: string;
    total_rooms: string;
    total_users: string;
    total_events: string;
    total_connections: string;
  };
};
```

---

## Key React Admin Components

### List View
```typescript
<List filters={[filters]} pagination={<Pagination />} sort={{ field: "id", order: "ASC" }}>
  <Datagrid>
    <TextField source="name" />
    <NumberField source="count" />
  </Datagrid>
</List>
```

### Show/Detail View
```typescript
<Show>
  <TabbedShowLayout>
    <Tab label="Overview" icon={<Icon />}>
      <TextField source="name" />
    </Tab>
    <Tab label="Details" path="details">
      <ArrayField source="items">
        <Datagrid>
          <TextField source="id" />
        </Datagrid>
      </ArrayField>
    </Tab>
  </TabbedShowLayout>
</Show>
```

### Form/Edit View
```typescript
<Edit>
  <SimpleForm>
    <TextInput source="name" validate={required()} />
    <NumberInput source="count" min={0} />
    <BooleanInput source="active" />
  </SimpleForm>
</Edit>
```

### Field Types
```typescript
<TextField source="name" />
<NumberField source="count" />
<DateField source="created_at" />
<BooleanField source="is_active" />
<ReferenceField source="user_id" reference="users">
  <TextField source="id" />
</ReferenceField>
<ArrayField source="items">
  <Datagrid>...</Datagrid>
</ArrayField>
```

---

## Common Patterns

### Pagination
```typescript
<Pagination rowsPerPageOptions={[10, 25, 50, 100, 500, 1000]} />
```

### Search Filter
```typescript
const filters = [
  <SearchInput source="search_term" alwaysOn />,
];

<List filters={filters}>
```

### Export Button
```typescript
<List actions={<ListActions />}>
  <Datagrid>
    <ExportButton />
  </Datagrid>
</List>
```

### Custom Actions Toolbar
```typescript
const ListActions = () => {
  const { isLoading, total } = useListContext();
  return (
    <TopToolbar>
      <CreateButton />
      <ExportButton disabled={isLoading || total === 0} />
      <DeleteButton />
    </TopToolbar>
  );
};
```

### Hooks for Components
```typescript
// Get list context
const { isLoading, total, data } = useListContext();

// Translate strings
const translate = useTranslate();
const label = translate("resources.users.fields.id");

// Get current record (in Show/Edit)
const record = useRecordContext();

// Trigger refetch
const refresh = useRefresh();

// Show notifications
const notify = useNotify();
notify("Success!", { type: "info" });

// Get data provider
const dataProvider = useDataProvider();
dataProvider.getList("resource", params);
```

---

## Data Provider Methods

### getList (Paginated List)
```typescript
// Query params
dataProvider.getList("users", {
  pagination: { page: 1, perPage: 25 },
  sort: { field: "name", order: "ASC" },
  filter: { admin: true, deactivated: false }
})
// Returns: { data: [...], total: 150 }
```

### getOne (Single Record)
```typescript
dataProvider.getOne("users", { id: "@user:example.com" })
// Returns: { data: {...} }
```

### getMany (Multiple Records)
```typescript
dataProvider.getMany("users", { ids: ["@user1:ex.com", "@user2:ex.com"] })
// Returns: { data: [{...}, {...}], total: 2 }
```

### getManyReference (Related Records)
```typescript
dataProvider.getManyReference("room_members", {
  target: "room_id",
  id: "!room:example.com",
  pagination: { page: 1, perPage: 25 },
  sort: { field: "id", order: "ASC" }
})
// Returns: { data: [...], total: 50 }
```

### create (Create Record)
```typescript
dataProvider.create("users", { data: { id: "newuser", displayname: "New User" } })
```

### update (Update Record)
```typescript
dataProvider.update("users", { id: "@user:ex.com", data: { displayname: "Updated" } })
```

### delete (Delete Record)
```typescript
dataProvider.delete("users", { id: "@user:ex.com" })
```

---

## Synapse API Endpoints (Admin)

```
# Users
GET /_synapse/admin/v2/users?from=0&limit=100&order_by=name
GET /_synapse/admin/v2/users/@user:domain
PUT /_synapse/admin/v2/users/@user:domain
DELETE /_synapse/admin/v1/deactivate/@user:domain

# Rooms
GET /_synapse/admin/v1/rooms
GET /_synapse/admin/v1/rooms/{roomId}
DELETE /_synapse/admin/v2/rooms/{roomId}

# Statistics
GET /_synapse/admin/v1/statistics/users/media
GET /_synapse/admin/v1/server_version

# Reports
GET /_synapse/admin/v1/event_reports
DELETE /_synapse/admin/v1/event_reports/{reportId}

# Devices
GET /_synapse/admin/v2/users/{userId}/devices
DELETE /_synapse/admin/v2/users/{userId}/devices/{deviceId}

# Media
GET /_synapse/admin/v1/users/{userId}/media
DELETE /_synapse/admin/v1/media/{servername}/{mediaId}
POST /_synapse/admin/v1/media/{servername}/delete?before_ts=X&size_gt=Y
```

---

## Testing

### Running Tests
```bash
yarn test              # Run all
yarn test:watch       # Watch mode
yarn test MyComponent # Specific file
```

### Test File Template
```typescript
// src/resources/server_statistics.test.tsx
import { render, screen } from "@testing-library/react";
import { AdminContext } from "react-admin";
import { ServerStatsList } from "./server_statistics";

describe("ServerStatsList", () => {
  it("renders the list", () => {
    render(
      <AdminContext>
        <ServerStatsList />
      </AdminContext>
    );
    expect(screen.getByText("Time")).toBeInTheDocument();
  });
});
```

---

## Common Issues & Solutions

### Issue: "id field is required"
**Solution**: Ensure the `map()` function adds `id` field:
```typescript
map: (stat) => ({
  ...stat,
  id: stat.timestamp,  // MUST be present
})
```

### Issue: API returns data but not showing
**Solution**: Check `data` key in resourceMap matches response structure:
```typescript
// If API response is { "stats": [...] }
data: "stats",

// If API response is { "results": [...] }
data: "results",
```

### Issue: Pagination shows 0 total
**Solution**: Check `total()` function matches response:
```typescript
// If response has { "total": 100 }
total: json => json.total,

// If response has { "results": [...], "count": 100 }
total: json => json.count,
```

### Issue: Translations not showing
**Solution**: 
1. Add to all i18n files (en.ts, de.ts, fr.ts, etc.)
2. Update index.d.ts with type definition
3. Use exact key path: `translate("resources.server_statistics.fields.timestamp")`

### Issue: Can't fetch data
**Solution**: Check:
1. Access token stored: `storage.getItem("access_token")`
2. Auth header in request: Should be `Bearer {token}`
3. API endpoint path: Should match Synapse admin API docs
4. CORS enabled on Synapse server

---

## Files to Check

Before adding features, review these files to understand patterns:

1. **Simple Resource** (read-only):
   - `/src/resources/user_media_statistics.tsx` (1461 bytes)

2. **Complex Resource** (with tabs, relationships):
   - `/src/resources/rooms.tsx` (9220 bytes)
   - `/src/resources/users.tsx` (12683 bytes)

3. **API Client**:
   - `/src/synapse/dataProvider.ts` (18 KB) - Core logic
   - Lines 228-478: Resource mappings
   - Lines 498-740: CRUD operations

4. **Internationalization**:
   - `/src/i18n/en.ts` - English structure
   - `/src/i18n/index.d.ts` - Type definitions

5. **Main App**:
   - `/src/App.tsx` - Resource registration

---

## Useful MUI Icons

```typescript
import EqualizerIcon from "@mui/icons-material/Equalizer";  // Stats
import ViewListIcon from "@mui/icons-material/ViewList";     // List
import PageviewIcon from "@mui/icons-material/Pageview";     // Details
import UserIcon from "@mui/icons-material/Group";            // Users
import RoomIcon from "@mui/icons-material/Room";             // Rooms
import ChartIcon from "@mui/icons-material/BarChart";        // Charts
import TrendingUpIcon from "@mui/icons-material/TrendingUp"; // Trends
import StorageIcon from "@mui/icons-material/Storage";       // Storage
import SpeedIcon from "@mui/icons-material/Speed";           // Performance
```

---

## Summary Checklist: Add New Statistics Feature

- [ ] Add TypeScript interface to `dataProvider.ts`
- [ ] Add resource mapping to `resourceMap` in `dataProvider.ts`
- [ ] Create resource component in `/src/resources/`
- [ ] Import and register `<Resource>` in `App.tsx`
- [ ] Add translations to `en.ts`, `de.ts`, `fr.ts`, `it.ts`, `ru.ts`, `zh.ts`, `fa.ts`
- [ ] Update `index.d.ts` with translation types
- [ ] Test the new resource loads and displays data
- [ ] Run linting: `yarn lint --fix`
- [ ] Run tests: `yarn test`
- [ ] Build: `yarn build`

