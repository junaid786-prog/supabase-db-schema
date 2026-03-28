# Supabase Multi-Tenant Architecture with RLS & PostGIS

A production-grade reference implementation demonstrating multi-tenant isolation using Supabase Row Level Security (RLS) and PostGIS spatial queries.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      Supabase Auth                          │
│                   (JWT + auth.uid())                        │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                   RLS Policy Layer                          │
│                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ Role Check  │  │  Permission  │  │   API Key Auth    │  │
│  │ (employee,  │  │   Check      │  │   (M2M access)    │  │
│  │  customer,  │  │ (CRUD per    │  │                   │  │
│  │  supplier)  │  │  module)     │  │                   │  │
│  └──────┬──────┘  └──────┬───────┘  └────────┬──────────┘  │
│         │                │                    │             │
│         └────────────────┼────────────────────┘             │
│                          ▼                                  │
│              get_companies_with_employee_permission()       │
│              get_companies_with_any_role()                  │
│              get_company_id_from_api_key()                  │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                    PostgreSQL Tables                        │
│                                                             │
│  ┌──────────┐  ┌──────────────┐  ┌───────────────────────┐ │
│  │ company  │  │ userToCompany│  │ tenant-scoped tables  │ │
│  │ (tenant) │◄─┤ (membership) │  │ (companyId FK)        │ │
│  └──────────┘  └──────────────┘  └───────────────────────┘ │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  PostGIS: location (geography), spatial queries      │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Key Concepts

### Multi-Tenancy Model

Each **company** is an isolated tenant. Users can belong to multiple companies with different roles:

| Role       | Description                                    |
|------------|------------------------------------------------|
| `employee` | Internal user with module-level CRUD permissions |
| `customer` | External customer with scoped read access       |
| `supplier` | External supplier with scoped read access       |

### Permission System

Permissions follow the pattern `{module}_{action}` (e.g., `inventory_view`, `purchasing_create`).

Permissions are stored per-user in JSONB and map to arrays of company IDs the user has that permission for. A special value `"0"` grants the permission across all companies.

```json
{
  "inventory_view": ["company_abc", "company_xyz"],
  "purchasing_create": ["company_abc"],
  "settings_update": ["0"]  // global access
}
```

### RLS Strategy

Every tenant-scoped table has four policies (SELECT, INSERT, UPDATE, DELETE) that call centralized helper functions:

```sql
-- Standard pattern for any tenant-scoped table
CREATE POLICY "SELECT" ON "inventory_item"
FOR SELECT USING (
  "companyId" = ANY(get_companies_with_employee_permission('inventory_view'))
);

CREATE POLICY "INSERT" ON "inventory_item"
FOR INSERT WITH CHECK (
  "companyId" = ANY(get_companies_with_employee_permission('inventory_create'))
);
```

### API Key Access (Machine-to-Machine)

API keys provide company-scoped access without a user session. The key is passed via HTTP header and resolved to a `companyId` at the RLS layer.

### PostGIS Spatial Queries

Locations store coordinates as `geography(Point, 4326)` for accurate distance calculations. Spatial queries enable:
- Finding nearby locations within a radius
- Distance calculations between points
- Bounding box searches

## Files

| File | Description |
|------|-------------|
| `schema.sql` | Core tables: users, companies, roles, permissions, locations (PostGIS) |
| `rls_policies.sql` | RLS helper functions and policies for all tables |
| `seed.sql` | Sample multi-tenant data with users, permissions, and locations |
| `sample_queries.sql` | Example queries demonstrating RLS behavior and PostGIS |

## Quick Start

```bash
# 1. Start a local Supabase instance
supabase init
supabase start

# 2. Apply schema
psql $DATABASE_URL -f schema.sql

# 3. Apply RLS policies
psql $DATABASE_URL -f rls_policies.sql

# 4. Load sample data
psql $DATABASE_URL -f seed.sql

# 5. Explore queries
psql $DATABASE_URL -f sample_queries.sql
```

## Design Decisions

1. **Company = Tenant**: The `company` table is the tenant boundary. Every business table references `companyId`.
2. **Centralized permission functions**: RLS policies delegate to `SECURITY DEFINER` functions rather than inline subqueries, improving maintainability and consistency.
3. **Role + Permission layering**: Role membership (via `userToCompany`) is checked *before* fine-grained permissions, creating a two-layer gate.
4. **Performance**: Permission functions use `(SELECT auth.uid())` pattern to avoid repeated JWT parsing per row.
5. **PostGIS geography type**: Uses `geography` (not `geometry`) for real-world distance calculations in meters without projection issues.

## License

MIT
