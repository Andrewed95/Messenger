# Synapse-Admin Data Flow Diagram

## Component Hierarchy

```
App.tsx
├── Admin (React Admin framework wrapper)
│   ├── QueryClientProvider (TanStack React Query)
│   │   └── Data caching & synchronization
│   │
│   ├── LoginPage (Authentication)
│   │   └── authProvider (manages tokens)
│   │       └── localStorage (stores access_token)
│   │
│   ├── CustomRoutes
│   │   └── /import_users -> ImportFeature
│   │
│   └── Resources (Auto-generates routes)
│       ├── /users -> UserList/UserEdit/UserCreate
│       ├── /rooms -> RoomList/RoomShow
│       ├── /user_media_statistics -> UserMediaStatsList
│       ├── /reports -> ReportList/ReportShow
│       ├── /destinations -> DestinationList
│       └── ... (more resources)
```

---

## Authentication Flow

```
┌─────────────────────────────────────────────────────────┐
│                  USER LOGIN                              │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
        ┌──────────────────────────────┐
        │ LoginPage.tsx                │
        │ - baseUrl input              │
        │ - username input             │
        │ - password input             │
        └──────────────────┬───────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────┐
        │ authProvider.login()                     │
        │ (authProvider.ts)                        │
        └──────────────────┬───────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────┐
        │ POST /_matrix/client/r0/login            │
        │ (Synapse API)                            │
        └──────────────────┬───────────────────────┘
                           │
        Response: access_token, user_id, device_id, home_server
                           │
                           ▼
        ┌──────────────────────────────────────────┐
        │ localStorage                             │
        │ - access_token                           │
        │ - user_id                                │
        │ - device_id                              │
        │ - home_server                            │
        │ - base_url                               │
        └──────────────────────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────┐
        │ authProvider.checkAuth()                 │
        │ Validates token exists before each page  │
        └──────────────────────────────────────────┘
```

---

## Data Fetching Flow (List View Example)

```
┌──────────────────────────────────────────────────────────────┐
│ User navigates to /user_media_statistics                     │
└───────────────────────┬──────────────────────────────────────┘
                        │
                        ▼
        ┌──────────────────────────────────────┐
        │ React Router matches route            │
        │ Creates UserMediaStatsList component  │
        └──────────────────┬───────────────────┘
                           │
                           ▼
        ┌────────────────────────────────────────────┐
        │ React Admin <List> component               │
        │ - Pagination: page=1, perPage=25           │
        │ - Sort: field="media_length", order="DESC" │
        │ - Filter: search_term=""                   │
        └──────────────────┬─────────────────────────┘
                           │
                           ▼
        ┌────────────────────────────────────────────────────┐
        │ dataProvider.getList()                             │
        │ (from dataProvider.ts)                             │
        │                                                    │
        │ Receives: resource="user_media_statistics"         │
        │           pagination, sort, filter params          │
        └──────────────────┬─────────────────────────────────┘
                           │
                           ▼
        ┌─────────────────────────────────────────────────────┐
        │ Look up resourceMap["user_media_statistics"]        │
        │                                                     │
        │ {                                                   │
        │   path: "/_synapse/admin/v1/statistics/users/media",│
        │   map: (usms) => ({ ...usms, id: usms.user_id }),  │
        │   data: "users",                                    │
        │   total: (json) => json.total                       │
        │ }                                                   │
        └──────────────────┬──────────────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────────────┐
        │ Build API request URL                                │
        │ base_url = localStorage.getItem("base_url")          │
        │ endpoint = base_url +                                │
        │   "/_synapse/admin/v1/statistics/users/media"        │
        │ query = "?from=0&limit=25&order_by=media_length"     │
        │         "&dir=b&search_term="                        │
        │                                                      │
        │ Full URL: https://synapse.example.com:8008/          │
        │   _synapse/admin/v1/statistics/users/media?...       │
        └──────────────────┬─────────────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────────────┐
        │ jsonClient() adds Bearer token header                │
        │ (from dataProvider.ts, line 15)                      │
        │                                                      │
        │ token = localStorage.getItem("access_token")         │
        │ Authorization: Bearer syt_xxxx...                    │
        └──────────────────┬─────────────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────────────┐
        │ HTTP GET request with Bearer token                   │
        │ (fetchUtils.fetchJson from react-admin)              │
        └──────────────────┬─────────────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────────────┐
        │ Synapse API Server                                   │
        │ /_synapse/admin/v1/statistics/users/media             │
        │                                                      │
        │ Response:                                            │
        │ {                                                    │
        │   "users": [                                         │
        │     {                                                │
        │       "user_id": "@user1:example.com",               │
        │       "displayname": "User One",                     │
        │       "media_count": 42,                             │
        │       "media_length": 1073741824                     │
        │     },                                               │
        │     ...                                              │
        │   ],                                                 │
        │   "total": 150                                       │
        │ }                                                    │
        └──────────────────┬─────────────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────────────┐
        │ Transform response with map() function               │
        │                                                      │
        │ Input: {                                             │
        │   "user_id": "@user1:example.com",                   │
        │   "displayname": "User One",                         │
        │   "media_count": 42,                                 │
        │   "media_length": 1073741824                         │
        │ }                                                    │
        │                                                      │
        │ Output: {                                            │
        │   "id": "@user1:example.com",  ← ADDED by map()      │
        │   "user_id": "@user1:example.com",                   │
        │   "displayname": "User One",                         │
        │   "media_count": 42,                                 │
        │   "media_length": 1073741824                         │
        │ }                                                    │
        └──────────────────┬─────────────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────────────┐
        │ Return from getList()                                │
        │                                                      │
        │ {                                                    │
        │   data: [                                            │
        │     { id: "@user1:...", ... },                       │
        │     { id: "@user2:...", ... },                       │
        │     ...                                              │
        │   ],                                                 │
        │   total: 150                                         │
        │ }                                                    │
        └──────────────────┬─────────────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────────────┐
        │ React Query caches the response                      │
        │ (TanStack React Query)                               │
        │                                                      │
        │ Cache key: ["user_media_statistics", params]         │
        └──────────────────┬─────────────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────────────┐
        │ React Admin <List> receives data                     │
        │ Renders <Datagrid> with rows                         │
        │                                                      │
        │ ┌─────────────────────────────────────────────────┐ │
        │ │ User ID          │ Display Name │ Count │ Length│ │
        │ ├──────────────────┼──────────────┼───────┼───────┤ │
        │ │ @user1:...       │ User One     │ 42    │ 1 GB  │ │
        │ │ @user2:...       │ User Two     │ 18    │ 512MB │ │
        │ │ ...              │ ...          │ ...   │ ...   │ │
        │ └─────────────────────────────────────────────────┘ │
        │                                                      │
        │ Shows pagination: Page 1 of 6                        │
        └──────────────────────────────────────────────────────┘
```

---

## Resource Registration Flow

```
/src/App.tsx
│
├─ Import resources
│  ├─ import users from "./resources/users"
│  ├─ import userMediaStats from "./resources/user_media_statistics"
│  └─ import reports from "./resources/reports"
│
└─ Register in <Admin> component
   ├─ <Resource {...users} />
   │  ├─ Reads users.name → "users"
   │  ├─ Reads users.list → UserList component
   │  ├─ Reads users.show → UserShow component
   │  ├─ Reads users.edit → UserEdit component
   │  ├─ Reads users.create → UserCreate component
   │  ├─ Reads users.icon → UserIcon
   │  │
   │  └─ React Admin generates routes:
   │     ├─ /users → UserList
   │     ├─ /users/new → UserCreate
   │     ├─ /users/:id → UserEdit
   │     └─ /users/:id/show → UserShow
   │
   ├─ <Resource {...userMediaStats} />
   │  ├─ Reads userMediaStats.name → "user_media_statistics"
   │  ├─ Reads userMediaStats.list → UserMediaStatsList
   │  ├─ Reads userMediaStats.icon → EqualizerIcon
   │  │
   │  └─ React Admin generates routes:
   │     └─ /user_media_statistics → UserMediaStatsList
   │
   └─ <Resource {...reports} />
      └─ ... (similar pattern)
```

---

## Data Provider Architecture

```
dataProvider.ts (Core API Client)
│
├─ jsonClient(url, options)
│  ├─ Gets access_token from localStorage
│  ├─ Adds Authorization: Bearer header
│  └─ Calls fetchUtils.fetchJson (react-admin utility)
│
├─ resourceMap object (Resource configurations)
│  │
│  ├─ users: { path, map, data, total, create, update, delete }
│  ├─ rooms: { path, map, data, total, ... }
│  ├─ user_media_statistics: { path, map, data, total }
│  ├─ devices: { reference, map, data, total, delete }
│  ├─ room_members: { reference, map, data, total }
│  └─ ... (13+ resources)
│
└─ CRUD Methods (async)
   ├─ getList(resource, params)
   │  └─ Call dataProvider.getList("users", { pagination, sort, filter })
   │  └─ Builds query string: ?from=X&limit=Y&order_by=Z
   │  └─ Calls GET path?query
   │  └─ Maps response with resourceMap[resource].map()
   │  └─ Returns { data: [...], total: N }
   │
   ├─ getOne(resource, id)
   │  └─ Call GET path/id
   │  └─ Maps response
   │  └─ Returns { data: {...} }
   │
   ├─ create(resource, data)
   │  └─ Call POST/PUT based on resourceMap[resource].create
   │  └─ Maps response
   │  └─ Returns { data: {...} }
   │
   ├─ update(resource, id, data)
   │  └─ Call PUT path/id with JSON body
   │  └─ Maps response
   │  └─ Returns { data: {...} }
   │
   ├─ delete(resource, id)
   │  └─ Call DELETE path/id
   │  └─ Returns { data: {...} }
   │
   ├─ getManyReference(resource, target, id)
   │  └─ Gets related data (e.g., devices for a user)
   │  └─ Builds reference endpoint
   │  └─ Returns { data: [...], total: N }
   │
   └─ deleteMedia(params)
       └─ Custom method for bulk media deletion
       └─ POST with before_ts and size_gt parameters
```

---

## State Management Flow

```
┌─────────────────────────────────────────────────────────┐
│ localStorage (Browser Storage)                          │
├─────────────────────────────────────────────────────────┤
│ access_token (Session token for API calls)              │
│ user_id      (Current logged-in user ID)                │
│ device_id    (Client device ID)                         │
│ home_server  (Matrix homeserver name)                   │
│ base_url     (API base URL)                             │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
        ┌─────────────────────────────────────┐
        │ storage.ts wrapper                  │
        │ - getItem(key)                      │
        │ - setItem(key, value)               │
        │ - removeItem(key)                   │
        └──────────────────┬──────────────────┘
                           │
    ┌──────────────────────┼──────────────────────┐
    ▼                      ▼                      ▼
dataProvider.ts    authProvider.ts       LoginPage.tsx
Gets token for     Uses for              Stores after
API calls          authorization         login


┌──────────────────────────────────────────────────────────┐
│ React Query Cache (TanStack React Query)                 │
├──────────────────────────────────────────────────────────┤
│ Key: ["resource_name", { pagination, sort, filter }]    │
│ Value: { data: [...], total: N }                         │
│                                                          │
│ Example cache entries:                                   │
│ ┌──────────────────────────────────────────────────────┐ │
│ │ ["users", {page:1, perPage:25}]                      │ │
│ │ → { data: [user1, user2, ...], total: 150 }          │ │
│ │                                                      │ │
│ │ ["user_media_statistics", {page:1}]                  │ │
│ │ → { data: [stat1, stat2, ...], total: 50 }           │ │
│ │                                                      │ │
│ │ ["rooms", {page:1, sort:"joined_members"}]           │ │
│ │ → { data: [room1, room2, ...], total: 200 }          │ │
│ └──────────────────────────────────────────────────────┘ │
│                                                          │
│ Features:                                                │
│ - Automatic background refetch                          │
│ - Stale data handling                                    │
│ - Cache invalidation on mutations                        │
│ - Optimistic updates                                     │
└──────────────────────────────────────────────────────────┘


┌──────────────────────────────────────────────────────────┐
│ React Component State (useState hooks)                   │
├──────────────────────────────────────────────────────────┤
│ - Form values (Create/Edit forms)                        │
│ - Dialog open/close state                                │
│ - Sort/filter settings (pagination state)                │
│ - Loading/error states                                   │
└──────────────────────────────────────────────────────────┘
```

---

## Adding New Statistics: Connection Points

```
1. API Response
   └─ Synapse returns: /_synapse/admin/v1/statistics/xxx

2. Data Provider (dataProvider.ts)
   ├─ Add interface: interface XxxStatistic { ... }
   └─ Add resourceMap entry:
      └─ xxx_statistics: {
           path: "/_synapse/admin/v1/statistics/xxx",
           map: (stat) => ({ ...stat, id: ... }),
           data: "data_key",
           total: (json) => json.total,
         }

3. Resource Component (resources/xxx_statistics.tsx)
   ├─ Define: XxxStatsList component
   └─ Export: ResourceProps with name, list, icon

4. App Registration (App.tsx)
   ├─ Import: import xxxStats from "./resources/xxx_statistics"
   └─ Register: <Resource {...xxxStats} />

5. i18n (i18n/*.ts files)
   └─ Add translations:
      └─ resources: {
           xxx_statistics: {
             name: "Xxx Statistics",
             fields: { ... }
           }
         }

6. Type Definitions (i18n/index.d.ts)
   └─ Add interface:
      └─ xxx_statistics: {
           name: string;
           fields: { ... };
         }

7. Menu & Routing (Automatic)
   └─ React Admin generates:
      └─ /xxx_statistics route
      └─ Menu item with icon
```

---

## Key Decisions Made by React Admin

```
1. Routing (Automatic)
   - Each <Resource> gets automatic CRUD routes
   - Format: /resource_name, /resource_name/new, /resource_name/:id
   - No need to manually define routes

2. Data Caching (TanStack React Query)
   - Response data cached with params as key
   - Stale after 5 minutes by default
   - Background refetch on window focus
   - Mutations invalidate related caches

3. UI Generation
   - <List> → pagination, sorting, filtering
   - <Show> → detail view with tabs
   - <Edit>/<Create> → forms with validation
   - Custom buttons (Export, Delete, etc.)

4. Internationalization
   - All strings use translation keys
   - Loaded based on browser locale
   - Plural forms with smart_count parameter
   - Translation fallback to English

5. Authentication
   - authProvider handles login/logout/checkAuth
   - Access token stored in localStorage
   - Checked before each route navigation
   - 401/403 errors trigger logout
```

