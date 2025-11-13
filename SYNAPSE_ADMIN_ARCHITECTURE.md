# Synapse-Admin Architecture Analysis

## Overview

**Synapse-Admin** is a web-based admin interface for the Matrix Synapse homeserver. It's built with:
- **Frontend Framework**: React 18.3.1 with TypeScript 5.4.5
- **Admin Framework**: React Admin 5.8.3 (a framework for building admin dashboards)
- **UI Components**: Material-UI (MUI) 7.1.0
- **Data Fetching**: TanStack React Query 5.59.12 (caching, synchronization)
- **Routing**: React Router 7.6.1
- **Build Tool**: Vite 6.3.5
- **State Management**: localStorage for authentication, React hooks for local state

---

## Directory Structure

```
synapse-admin/
├── src/
│   ├── App.tsx                    # Main app component (routing setup)
│   ├── AppContext.tsx             # App-wide context
│   ├── index.tsx                  # Entry point
│   ├── storage.ts                 # localStorage wrapper
│   │
│   ├── components/                # Reusable UI components
│   │   ├── AvatarField.tsx
│   │   ├── ImportFeature.tsx       # Bulk user import UI
│   │   ├── ServerNotices.tsx       # Server notice buttons
│   │   ├── media.tsx              # Media management (delete, protect, quarantine)
│   │   ├── devices.tsx            # Device management
│   │   └── date.ts                # Date formatting utilities
│   │
│   ├── pages/                     # Full-page components
│   │   └── LoginPage.tsx          # Authentication/login
│   │
│   ├── resources/                 # Resource definitions (Collections)
│   │   ├── users.tsx              # User management (list, create, edit)
│   │   ├── rooms.tsx              # Room management
│   │   ├── user_media_statistics.tsx  # EXISTING STATS: User media usage
│   │   ├── reports.tsx            # Content reports/abuse
│   │   ├── destinations.tsx       # Federation destinations
│   │   ├── registration_tokens.tsx
│   │   └── room_directory.tsx
│   │
│   ├── synapse/                   # API integration layer
│   │   ├── synapse.ts             # Utility functions (version, features, login flows)
│   │   ├── authProvider.ts        # Authentication logic
│   │   └── dataProvider.ts        # Core API client + resource mappings
│   │
│   └── i18n/                      # Internationalization
│       ├── en.ts
│       ├── de.ts
│       ├── fr.ts
│       ├── it.ts
│       ├── ru.ts
│       ├── zh.ts
│       ├── fa.ts
│       └── index.d.ts             # Type definitions for translations
```

---

## Core Architecture Patterns

### 1. React Admin Framework Pattern

**React Admin** provides a structured approach to building admin UIs:

```typescript
// App.tsx - Main routing structure
const App = () => (
  <QueryClientProvider client={queryClient}>
    <Admin
      disableTelemetry
      requireAuth
      loginPage={LoginPage}
      authProvider={authProvider}
      dataProvider={dataProvider}
      i18nProvider={i18nProvider}
    >
      <CustomRoutes>
        <Route path="/import_users" element={<ImportFeature />} />
      </CustomRoutes>
      
      {/* Resource definitions - maps to CRUD operations */}
      <Resource {...users} />           // /users (list, show, edit, create)
      <Resource {...rooms} />           // /rooms
      <Resource {...userMediaStats} /> // /user_media_statistics
      <Resource {...reports} />        // /reports
      ...
    </Admin>
  </QueryClientProvider>
);
```

### 2. Data Provider Pattern

The **dataProvider** is the core API client that handles all HTTP requests:

```typescript
// src/synapse/dataProvider.ts
interface SynapseDataProvider extends DataProvider {
  getList()      // GET list of resources (paginated)
  getOne()       // GET single resource
  create()       // POST create resource
  update()       // PUT update resource
  delete()       // DELETE resource
  getManyReference() // GET related resources
  deleteMedia()  // Custom method for bulk media deletion
}
```

**Resource Mapping Configuration** (lines 228-478 in dataProvider.ts):

Each resource has:
- `path`: API endpoint path
- `map()`: Transform API response to UI format
- `data`: Key in response containing array of items
- `total()`: Function to extract total count
- `reference()`: Function for nested endpoints (relationships)
- Optional: `create()`, `update()`, `delete()` custom implementations

```typescript
resourceMap = {
  user_media_statistics: {
    path: "/_synapse/admin/v1/statistics/users/media",
    map: (usms: UserMediaStatistic) => ({
      ...usms,
      id: usms.user_id,  // React Admin requires 'id' field
    }),
    data: "users",
    total: json => json.total,
  },
}
```

---

## Synapse API Connection

### Authentication Flow

```
1. User submits base_url + credentials (LoginPage.tsx)
2. authProvider.login() -> POST /_matrix/client/r0/login
3. Returns: access_token, user_id, device_id, home_server
4. Stored in localStorage via storage.ts
5. All subsequent requests include Bearer token
```

**Auth Headers** (dataProvider.ts, line 15-24):
```typescript
const jsonClient = (url: string, options: Options = {}) => {
  const token = storage.getItem("access_token");
  if (token != null) {
    options.user = {
      authenticated: true,
      token: `Bearer ${token}`,
    };
  }
  return fetchUtils.fetchJson(url, options);
};
```

### API Endpoint Examples

| Resource | Endpoint | Method |
|----------|----------|--------|
| Users | `/_synapse/admin/v2/users` | GET/PUT/DELETE |
| Rooms | `/_synapse/admin/v1/rooms` | GET/DELETE |
| **User Media Stats** | `/_synapse/admin/v1/statistics/users/media` | GET |
| Reports | `/_synapse/admin/v1/event_reports` | GET/DELETE |
| Devices | `/_synapse/admin/v2/users/{userId}/devices` | GET/DELETE |
| Server Version | `/_synapse/admin/v1/server_version` | GET |

---

## Existing Statistics Implementation

### User Media Statistics (Current Example)

**Location**: `/src/resources/user_media_statistics.tsx`

```typescript
// Simple statistics resource
const resource: ResourceProps = {
  name: "user_media_statistics",
  icon: EqualizerIcon,
  list: UserMediaStatsList,  // Only has list view
};

// UI: Datagrid with columns
<Datagrid>
  <TextField source="user_id" />
  <TextField source="displayname" />
  <NumberField source="media_count" />
  <NumberField source="media_length" />
</Datagrid>
```

**Features**:
- Simple list view (read-only)
- Pagination with 1000 rows/page
- Search by user
- Export to CSV
- Media deletion via custom component

**Type Definition** (dataProvider.ts, lines 180-185):
```typescript
interface UserMediaStatistic {
  displayname: string;
  media_count: number;
  media_length: number;
  user_id: string;
}
```

**Data Flow**:
1. User navigates to "Users' media" menu item
2. React Admin calls `dataProvider.getList('user_media_statistics', params)`
3. Data provider makes GET request to `/_synapse/admin/v1/statistics/users/media?from=0&limit=25&...`
4. Response mapped and rendered in Datagrid

---

## Routing Structure

### Default Routes (Generated by React Admin)

React Admin automatically creates routes for each Resource:

```
/users                    -> UserList
/users/new               -> UserCreate
/users/:id               -> UserEdit (with tabs)
/users/:id/show          -> UserShow

/rooms                   -> RoomList
/rooms/:id               -> RoomShow (with tabs)

/user_media_statistics   -> UserMediaStatsList
/reports                 -> ReportList
/reports/:id             -> ReportShow (with tabs)

/destinations            -> DestinationList
/registration_tokens     -> RegistrationTokenList
```

### Custom Routes

```typescript
<CustomRoutes>
  <Route path="/import_users" element={<ImportFeature />} />
</CustomRoutes>
```

Custom routes are defined in App.tsx for non-CRUD pages.

---

## Data Fetching Patterns

### Pattern 1: List View with Pagination, Filtering, Sorting

```typescript
// getList implementation (dataProvider.ts)
export const UserList = (props: ListProps) => (
  <List
    sort={{ field: "name", order: "ASC" }}
    filters={[<SearchInput source="name" alwaysOn />]}
    pagination={<Pagination rowsPerPageOptions={[10, 25, 50]} />}
  >
    <Datagrid rowClick="show">
      <TextField source="id" />
      <TextField source="displayname" />
      <BooleanField source="admin" />
      <TextField source="creation_ts" />
    </Datagrid>
  </List>
);
```

**Request Parameters**:
```
GET /users?from=0&limit=25&order_by=name&dir=f&search_term=john
      └─ from: offset
      └─ limit: per page
      └─ order_by: sort field
      └─ dir: 'f' (forward/ASC) or 'b' (backward/DESC)
      └─ search_term: filter
```

### Pattern 2: Show/Detail View with Tabs

```typescript
export const RoomShow = (props: ShowProps) => (
  <Show {...props}>
    <TabbedShowLayout>
      <Tab label="Basic" icon={<ViewListIcon />}>
        <TextField source="room_id" />
        <TextField source="name" />
        <NumberField source="joined_members" />
      </Tab>
      
      <Tab label="Members" path="members">
        <ReferenceManyField reference="room_members" target="room_id">
          <Datagrid>
            <TextField source="id" />
          </Datagrid>
        </ReferenceManyField>
      </Tab>
    </TabbedShowLayout>
  </Show>
);
```

**Data Fetching**:
- `getOne()` - Initial resource data
- `getManyReference()` - Related data in tabs

### Pattern 3: Custom Hook Pattern

```typescript
// Using React Admin hooks
const UserMediaStatsList = (props: ListProps) => {
  const { isLoading, total } = useListContext(); // Current list state
  const translate = useTranslate();               // i18n
  const notify = useNotify();                     // Toast notifications
  
  return (
    <List>
      <Datagrid>
        ...
      </Datagrid>
    </List>
  );
};
```

### Pattern 4: React Query Integration

TanStack React Query is used for server state management:

```typescript
// Automatic caching, background refresh, etc.
<QueryClientProvider client={queryClient}>
  <Admin {...props} />
</QueryClientProvider>
```

---

## Internationalization (i18n)

### Translation Structure

All UI strings are defined in `/src/i18n/*.ts` files:

```typescript
// en.ts
const en = {
  synapseadmin: {
    auth: { ... },
    users: { ... },
    rooms: { ... },
  },
  delete_media: {
    name: "Media",
    fields: { ... },
  },
  resources: {
    users: {
      name: "User",
      fields: {
        id: "User ID",
        displayname: "Display name",
      },
    },
  },
};
```

**Type Definition** (index.d.ts):
```typescript
interface SynapseTranslationMessages extends TranslationMessages {
  synapseadmin: { ... }
  resources: { ... }
}
```

### Using Translations in Components

```typescript
// In components
const translate = useTranslate();

// In JSX
<label>{translate("resources.users.fields.id")}</label>

// With interpolation
<label>{translate("import_users.cards.importstats.users_total", 
  { smart_count: count })}</label>
```

---

## Component Types

### 1. Resource Components (Full CRUD)

```typescript
interface ResourceProps {
  name: string;           // Resource identifier
  icon: ReactNode;        // Menu icon (MUI icon)
  list?: Component;       // List view
  show?: Component;       // Detail view (read-only)
  edit?: Component;       // Edit form
  create?: Component;     // Create form
}
```

**Example**: `/src/resources/users.tsx`

### 2. Standalone Components

```typescript
// /src/components/media.tsx
export const DeleteMediaButton = () => {
  const dataProvider = useDataProvider();
  const { mutate } = useMutation();
  
  return (
    <Button onClick={() => mutate()} label="Delete" />
  );
};
```

### 3. Form Components

```typescript
// React Admin provides built-in form components
<TextInput source="fieldName" validate={[required()]} />
<NumberInput source="count" min={0} />
<BooleanInput source="isActive" />
<SelectInput source="type" choices={[...]} />
<DateTimeInput source="created_at" />
<PasswordInput source="password" />
<ArrayInput source="items">
  <SimpleFormIterator>
    <TextInput source="item" />
  </SimpleFormIterator>
</ArrayInput>
```

---

## How to Add New Statistics Features

### Step 1: Add Data Provider Resource Mapping

**File**: `/src/synapse/dataProvider.ts`

```typescript
// Add to resourceMap (around line 228)
resourceMap = {
  // ... existing resources
  
  server_statistics: {
    path: "/_synapse/admin/v1/statistics/server",  // New endpoint
    map: (stat: ServerStatistic) => ({
      ...stat,
      id: stat.timestamp,  // IMPORTANT: React Admin requires 'id'
    }),
    data: "stats",
    total: json => json.total,
  },
};

// Add TypeScript interface
interface ServerStatistic {
  timestamp: number;
  total_rooms: number;
  total_users: number;
  total_events: number;
}
```

### Step 2: Create Resource Component

**File**: `/src/resources/server_statistics.tsx`

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

const ServerStatsFilters = [<SearchInput source="search_term" alwaysOn />];

export const ServerStatsList = (props: ListProps) => (
  <List {...props} filters={ServerStatsFilters}>
    <Datagrid rowClick="show">
      <TextField source="timestamp" />
      <NumberField source="total_rooms" />
      <NumberField source="total_users" />
      <NumberField source="total_events" />
    </Datagrid>
  </List>
);

export const ServerStatsShow = (props: ShowProps) => (
  <Show {...props}>
    <TabbedShowLayout>
      <Tab label="Overview" icon={<ViewListIcon />}>
        <TextField source="timestamp" />
        <NumberField source="total_rooms" />
        <NumberField source="total_users" />
        <NumberField source="total_events" />
      </Tab>
      
      <Tab label="Details" path="details">
        {/* More detailed stats */}
      </Tab>
    </TabbedShowLayout>
  </Show>
);

const resource: ResourceProps = {
  name: "server_statistics",
  icon: EqualizerIcon,
  list: ServerStatsList,
  show: ServerStatsShow,
};

export default resource;
```

### Step 3: Register Resource in App.tsx

```typescript
// /src/App.tsx
import serverStats from "./resources/server_statistics";

const App = () => (
  <QueryClientProvider client={queryClient}>
    <Admin {...props}>
      {/* ... */}
      <Resource {...userMediaStats} />
      <Resource {...serverStats} />  {/* Add new resource */}
      {/* ... */}
    </Admin>
  </QueryClientProvider>
);
```

### Step 4: Add i18n Translations

**File**: `/src/i18n/en.ts`

```typescript
const en: SynapseTranslationMessages = {
  // ... existing translations
  resources: {
    // ... existing resources
    server_statistics: {
      name: "Server Statistics",
      fields: {
        timestamp: "Timestamp",
        total_rooms: "Total Rooms",
        total_users: "Total Users",
        total_events: "Total Events",
      },
    },
  },
};
```

Repeat for other languages: `de.ts`, `fr.ts`, `it.ts`, `ru.ts`, `zh.ts`, `fa.ts`

### Step 5: Update Translation Types

**File**: `/src/i18n/index.d.ts`

```typescript
interface SynapseTranslationMessages extends TranslationMessages {
  resources: {
    server_statistics: {
      name: string;
      fields: {
        timestamp: string;
        total_rooms: string;
        total_users: string;
        total_events: string;
      };
    };
  };
}
```

---

## Advanced Statistics Features

### 1. Dashboard Overview (Custom Route)

```typescript
// /src/pages/StatisticsDashboard.tsx
import { useDataProvider } from "react-admin";
import { LineChart, BarChart } from "@mui/x-charts";

export const StatisticsDashboard = () => {
  const dataProvider = useDataProvider();
  const [stats, setStats] = useState(null);
  
  useEffect(() => {
    // Fetch multiple statistics at once
    Promise.all([
      dataProvider.getList('server_statistics', { pagination: { page: 1, perPage: 1 } }),
      dataProvider.getList('user_media_statistics', { pagination: { page: 1, perPage: 10 } }),
    ]).then(([serverStats, mediaStats]) => {
      setStats({ serverStats, mediaStats });
    });
  }, []);
  
  return (
    <Box>
      <Typography variant="h4">Server Dashboard</Typography>
      <LineChart data={stats?.serverStats} />
      <BarChart data={stats?.mediaStats} />
    </Box>
  );
};
```

Register in App.tsx:
```typescript
<CustomRoutes>
  <Route path="/dashboard" element={<StatisticsDashboard />} />
  <Route path="/import_users" element={<ImportFeature />} />
</CustomRoutes>
```

### 2. Real-time Updates (useRefresh Hook)

```typescript
const component = () => {
  const refresh = useRefresh();
  
  useEffect(() => {
    const interval = setInterval(() => {
      refresh();  // Refetch data from server
    }, 5000);    // Every 5 seconds
    
    return () => clearInterval(interval);
  }, [refresh]);
  
  return <List />;
};
```

### 3. Export Functionality

React Admin provides built-in export:

```typescript
<List {...props} actions={<ListActions />}>
  <Datagrid {...props}>
    <ExportButton />  // Automatic CSV export
  </Datagrid>
</List>
```

### 4. Bulk Actions

```typescript
const BulkActionButtons = () => (
  <>
    <BulkDeleteButton />
    <CustomBulkButton />  // Custom action
  </>
);

<Datagrid bulkActionButtons={<BulkActionButtons />}>
  {/* columns */}
</Datagrid>
```

---

## Testing

### Test Files Structure

```
src/
├── App.test.tsx
├── synapse/
│   ├── authProvider.test.ts
│   ├── dataProvider.test.ts
│   └── synapse.test.ts
├── components/
│   └── AvatarField.test.tsx
└── pages/
    └── LoginPage.test.tsx
```

### Running Tests

```bash
yarn test              # Run all tests
yarn test:watch       # Watch mode
```

---

## Key Files Reference

| File | Purpose | Key Functions |
|------|---------|----------------|
| `App.tsx` | Main routing & setup | Resource registration, custom routes |
| `dataProvider.ts` | API client | `getList()`, `getOne()`, `create()`, `update()`, `delete()` |
| `authProvider.ts` | Authentication | `login()`, `logout()`, `checkAuth()` |
| `synapse.ts` | Synapse utilities | `splitMxid()`, `getWellKnownUrl()`, `getSupportedFeatures()` |
| `storage.ts` | Local storage wrapper | `getItem()`, `setItem()`, `removeItem()` |
| `resources/*.tsx` | Feature components | List, Show, Edit, Create views |
| `components/*.tsx` | Reusable components | Custom fields, buttons, dialogs |
| `i18n/*.ts` | Translations | String definitions per language |

---

## Development Workflow

### 1. Setup
```bash
cd /home/user/Messenger/synapse-admin
yarn install
```

### 2. Development Server
```bash
yarn start
# Opens http://localhost:5173
```

### 3. Build for Production
```bash
yarn build
# Creates /dist folder
```

### 4. Linting
```bash
yarn lint          # Check code style
yarn fix           # Auto-fix issues
```

### 5. Testing
```bash
yarn test          # Run tests
yarn test:watch    # Watch mode
```

---

## Summary: Adding Statistics Features

### Minimal Example (5 steps):

1. **Define API mapping** in `dataProvider.ts` resourceMap
2. **Create resource component** in `resources/stats.tsx`
3. **Register in App.tsx** as `<Resource {...stats} />`
4. **Add translations** to all i18n files
5. **Update i18n types** in `index.d.ts`

### For Advanced Features:
- Create custom routes for dashboards
- Use `useDataProvider()` hook to fetch custom data
- Add charts with `@mui/x-charts`
- Implement real-time updates with `useRefresh()`
- Add bulk operations with `BulkDeleteButton`, custom bulk buttons
- Export data with `ExportButton`

---

## Architecture Strengths

1. **Well-structured**: Separation of concerns (components, resources, API)
2. **Type-safe**: Full TypeScript support throughout
3. **Reusable**: React Admin provides common patterns
4. **Extensible**: Easy to add new resources and features
5. **Internationalized**: Multi-language support built-in
6. **Tested**: Jest + React Testing Library setup ready
7. **Modern stack**: React 18, Vite, TanStack Query

