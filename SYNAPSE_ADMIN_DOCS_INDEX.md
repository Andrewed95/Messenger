# Synapse-Admin Documentation Index

## Complete Architecture Documentation for Statistics Features

This comprehensive documentation package covers everything you need to understand and extend synapse-admin's architecture for adding statistics features.

---

## Documentation Files

### 1. SYNAPSE_ADMIN_ARCHITECTURE.md (20 KB)
**Comprehensive architecture guide covering:**
- Overall structure (React, TypeScript, React Admin)
- Directory structure with full explanations
- Core architecture patterns (React Admin framework, Data Provider)
- Synapse API connection and authentication flow
- Existing statistics implementation (User Media Statistics)
- Routing structure (automatic & custom routes)
- Data fetching patterns (4 different patterns)
- Internationalization (i18n) system
- Component types and examples
- How to add new statistics features (5-step process)
- Advanced statistics features (dashboards, real-time updates, exports)
- Testing setup
- Key files reference

**Best for:** Understanding the big picture and learning where everything fits

---

### 2. SYNAPSE_ADMIN_QUICK_REFERENCE.md (12 KB)
**Quick lookup guide with:**
- File locations summary
- Statistics features currently implemented
- Step-by-step guide to add new statistics (Server Statistics example)
- Key React Admin components with code examples
- Common patterns (pagination, search, export, custom actions)
- React Admin hooks for components
- Data Provider methods and syntax
- Synapse API endpoints reference
- Testing guide
- Common issues and solutions
- Files to review before adding features
- Useful Material-UI icons
- Summary checklist for adding new features

**Best for:** Quick copy-paste code examples and troubleshooting

---

### 3. SYNAPSE_ADMIN_DATA_FLOW.md (10 KB)
**Visual diagrams and data flow explanations:**
- Component hierarchy tree
- Authentication flow diagram
- Data fetching flow (complete example)
- Resource registration flow
- Data provider architecture
- State management flow (localStorage, React Query, React state)
- Adding new statistics connection points
- Key decisions made by React Admin

**Best for:** Understanding how data flows through the system

---

## Quick Start: Adding Statistics Features

### The 5-Step Process

1. **dataProvider.ts** - Add resource mapping
   ```typescript
   interface YourStatistic { ... }
   resourceMap.your_statistics = { path, map, data, total }
   ```

2. **resources/your_statistics.tsx** - Create UI component
   ```typescript
   export const YourStatsList = (props) => <List><Datagrid>...</Datagrid></List>
   export const resource = { name, icon, list }
   ```

3. **App.tsx** - Register resource
   ```typescript
   import yourStats from "./resources/your_statistics"
   <Resource {...yourStats} />
   ```

4. **i18n/*.ts** - Add translations to all language files
   ```typescript
   your_statistics: { name: "...", fields: { ... } }
   ```

5. **i18n/index.d.ts** - Add TypeScript types
   ```typescript
   your_statistics: { name: string; fields: { ... } }
   ```

---

## Key Architecture Points

### React Admin Framework
- Automatic CRUD routes from `<Resource>` definitions
- `dataProvider` is the API client
- `authProvider` handles authentication
- `i18nProvider` handles translations
- TanStack React Query for caching

### Data Provider Pattern
```
resourceMap[resource_name] = {
  path: "API_endpoint_path",
  map: (apiData) => ({ ...apiData, id: uniqueId }),
  data: "array_key_in_response",
  total: (json) => json.total_count
}
```

### Resource Structure
```typescript
const resource: ResourceProps = {
  name: "resource_name",      // Used in routes & API
  icon: MuiIcon,              // Menu icon
  list: ListComponent,        // Required: List view
  show?: ShowComponent,       // Detail view
  edit?: EditComponent,       // Edit form
  create?: CreateComponent,   // Create form
}
```

---

## File Organization

```
/home/user/Messenger/synapse-admin/src/
├── synapse/
│   └── dataProvider.ts              [MODIFY] Add resource mappings
├── resources/
│   ├── user_media_statistics.tsx    [REFERENCE] Simple example
│   └── your_statistics.tsx          [CREATE] New feature
├── components/                      [MODIFY] Custom buttons/components
├── i18n/
│   ├── en.ts                        [MODIFY] Add translations
│   ├── de.ts, fr.ts, it.ts, ...    [MODIFY] Other languages
│   └── index.d.ts                   [MODIFY] Type definitions
├── App.tsx                          [MODIFY] Register resource
└── pages/                           [REFERENCE] LoginPage pattern
```

---

## Common Queries & Answers

**Q: Where does the API data come from?**
A: Synapse Admin API endpoints (e.g., `/_synapse/admin/v1/statistics/users/media`)

**Q: How are routes created?**
A: Automatically by React Admin from `<Resource>` definitions

**Q: Where is user authentication stored?**
A: localStorage (access_token, user_id, device_id, home_server, base_url)

**Q: How do I add translations?**
A: Update all i18n files (en.ts, de.ts, fr.ts, it.ts, ru.ts, zh.ts, fa.ts) and index.d.ts

**Q: How does data get cached?**
A: TanStack React Query caches responses with params as cache key

**Q: Can I add custom pages?**
A: Yes, use `<CustomRoutes>` in App.tsx

**Q: How do I handle related data (e.g., devices for a user)?**
A: Use `<ReferenceManyField>` or `getManyReference` in dataProvider

**Q: How are API calls made?**
A: Through `dataProvider.getList()`, `getOne()`, `create()`, `update()`, `delete()`

---

## Stack Overview

| Layer | Technology | Purpose |
|-------|-----------|---------|
| **Framework** | React 18.3.1 | Component-based UI |
| **Language** | TypeScript 5.4.5 | Type safety |
| **Admin UI** | React Admin 5.8.3 | CRUD framework |
| **UI Components** | Material-UI 7.1.0 | Visual components |
| **Routing** | React Router 7.6.1 | Client-side routing |
| **Data Fetching** | TanStack RQ 5.59.12 | Server state management |
| **Build Tool** | Vite 6.3.5 | Fast development |
| **Testing** | Jest 29.7.0 | Unit tests |
| **Linting** | ESLint 8.57.0 | Code quality |

---

## Real Examples in Codebase

### Simple Stats Resource (Read-Only)
**File:** `/home/user/Messenger/synapse-admin/src/resources/user_media_statistics.tsx`
- 56 lines of code
- Simple list view
- Pagination, search, export
- Good starting point

### Complex Resource (Full CRUD with Tabs)
**File:** `/home/user/Messenger/synapse-admin/src/resources/rooms.tsx`
- 284 lines of code
- List view with bulk actions
- Detail view with tabs
- Relationships to other resources
- Advanced UI patterns

### API Client
**File:** `/home/user/Messenger/synapse-admin/src/synapse/dataProvider.ts`
- 743 lines
- 13+ resource mappings
- Core CRUD logic
- Custom methods for special operations

---

## Development Commands

```bash
# Setup
cd /home/user/Messenger/synapse-admin
yarn install

# Development
yarn start              # Start dev server (http://localhost:5173)
yarn lint              # Check code style
yarn fix               # Auto-fix style issues
yarn test              # Run tests
yarn test:watch       # Watch mode for tests

# Production
yarn build             # Build for production
```

---

## Next Steps

1. **Read Architecture**: Start with `SYNAPSE_ADMIN_ARCHITECTURE.md` for overview
2. **Review Examples**: Check `user_media_statistics.tsx` (simple) and `rooms.tsx` (complex)
3. **Understand Flow**: Review data flow diagrams in `SYNAPSE_ADMIN_DATA_FLOW.md`
4. **Use Quick Reference**: Use `SYNAPSE_ADMIN_QUICK_REFERENCE.md` while coding
5. **Follow 5-Step Process**: Add your new statistics feature step by step
6. **Test & Verify**: Run `yarn test` and test in browser
7. **Deploy**: Run `yarn build` for production

---

## Support Resources

- **React Admin Docs**: https://marmelab.com/react-admin/
- **React Docs**: https://react.dev/
- **Material-UI Docs**: https://mui.com/
- **TanStack Query Docs**: https://tanstack.com/query/latest
- **Synapse Admin Repo**: https://github.com/Awesome-Technologies/synapse-admin
- **Matrix Spec**: https://spec.matrix.org/

---

## Documentation Version
- **Created**: 2025-11-13
- **Synapse-Admin Version**: 0.10.3
- **React**: 18.3.1
- **React Admin**: 5.8.3
- **TypeScript**: 5.4.5

---

## File Locations

All files are located in `/home/user/Messenger/`:

```
SYNAPSE_ADMIN_ARCHITECTURE.md       (Comprehensive guide)
SYNAPSE_ADMIN_QUICK_REFERENCE.md    (Quick lookup & examples)
SYNAPSE_ADMIN_DATA_FLOW.md          (Visual diagrams)
SYNAPSE_ADMIN_DOCS_INDEX.md         (This file)

synapse-admin/                       (Actual codebase)
├── src/
│   ├── App.tsx
│   ├── synapse/dataProvider.ts
│   ├── resources/user_media_statistics.tsx
│   └── i18n/
```

---

## How to Use This Documentation

### If you want to...

- **Understand the overall architecture** → Read SYNAPSE_ADMIN_ARCHITECTURE.md (sections 1-5)
- **Add a new statistics feature** → Read SYNAPSE_ADMIN_QUICK_REFERENCE.md (5-step process)
- **Understand how data flows** → Read SYNAPSE_ADMIN_DATA_FLOW.md
- **Copy code examples** → Find in SYNAPSE_ADMIN_QUICK_REFERENCE.md
- **Learn the codebase structure** → Read SYNAPSE_ADMIN_ARCHITECTURE.md (Directory Structure section)
- **See existing patterns** → Review files referenced in SYNAPSE_ADMIN_QUICK_REFERENCE.md
- **Troubleshoot issues** → Check "Common Issues & Solutions" in SYNAPSE_ADMIN_QUICK_REFERENCE.md
- **Understand specific concepts** → Search relevant documentation or consult SYNAPSE_ADMIN_DATA_FLOW.md

---

## Summary

You now have complete documentation for synapse-admin's architecture:

1. **SYNAPSE_ADMIN_ARCHITECTURE.md** - Complete reference (800 lines)
2. **SYNAPSE_ADMIN_QUICK_REFERENCE.md** - Practical guide (489 lines)
3. **SYNAPSE_ADMIN_DATA_FLOW.md** - Visual diagrams (400+ lines)
4. **SYNAPSE_ADMIN_DOCS_INDEX.md** - This index (this file)

This covers everything needed to:
- Understand how synapse-admin works
- See how it connects to Synapse API
- Find existing statistics features
- Learn the routing structure
- Understand where API calls are made
- Review component and page patterns
- Add new statistics features

Happy coding!

