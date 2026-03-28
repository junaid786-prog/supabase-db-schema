-- =============================================================================
-- Sample Queries: RLS Behavior & PostGIS Spatial Operations
-- =============================================================================
-- These queries demonstrate how RLS and PostGIS work together in a
-- multi-tenant environment. Run them after applying schema, policies, and seed.
-- =============================================================================


-- =========================================================================
-- PART 1: RLS Tenant Isolation
-- =========================================================================

-- 1.1 Simulate Alice (Acme admin) — sees only Acme data
-- In a real Supabase app, auth.uid() is set by the JWT. Here we show what
-- the RLS functions would return for each user.

SELECT get_companies_with_employee_permission('inventory_view');
-- Expected for Alice: {acme-corp}
-- Expected for Bob:   {acme-corp}  (view only)
-- Expected for Carol: {bolt-mfg}
-- Expected for Dave:  {}           (not an employee)


-- 1.2 Items visible per user (tenant isolation in action)
-- Alice and Bob see Acme items. Carol sees Bolt items. Dave sees nothing.

SELECT i."name", i."partNumber", c."name" AS "company"
FROM "item" i
JOIN "company" c ON c."id" = i."companyId"
WHERE i."companyId" = ANY(get_companies_with_employee_permission('inventory_view'));


-- 1.3 Permission escalation check
-- Bob can view but NOT create inventory items

SELECT get_companies_with_employee_permission('inventory_create');
-- Expected for Bob: {} (empty — no create permission)


-- 1.4 Cross-tenant user: Dave belongs to two companies with different roles
SELECT
    uc."companyId",
    c."name",
    uc."role"
FROM "userToCompany" uc
JOIN "company" c ON c."id" = uc."companyId"
WHERE uc."userId" = 'user-dave';
-- Returns:
--   acme-corp | Acme Manufacturing   | customer
--   bolt-mfg  | Bolt Precision Works | supplier


-- =========================================================================
-- PART 2: PostGIS Spatial Queries
-- =========================================================================

-- 2.1 Find all locations within 25 km of downtown Detroit
-- Uses ST_DWithin on geography type (distance in meters)

SELECT
    l."name",
    l."type",
    l."city",
    ROUND(ST_Distance(
        l."coordinates",
        ST_SetSRID(ST_MakePoint(-83.0458, 42.3314), 4326)::geography
    )::numeric) AS "distance_meters"
FROM "location" l
WHERE ST_DWithin(
    l."coordinates",
    ST_SetSRID(ST_MakePoint(-83.0458, 42.3314), 4326)::geography,
    25000  -- 25 km radius
)
ORDER BY "distance_meters";


-- 2.2 Distance matrix between all locations of a single tenant

SELECT
    a."name" AS "from",
    b."name" AS "to",
    ROUND(ST_Distance(a."coordinates", b."coordinates")::numeric) AS "distance_meters"
FROM "location" a
CROSS JOIN "location" b
WHERE a."companyId" = 'acme-corp'
  AND b."companyId" = 'acme-corp'
  AND a."id" < b."id"
ORDER BY "distance_meters";


-- 2.3 Find the nearest Acme location to a given point (job site in Toledo, OH)

SELECT
    l."name",
    l."city",
    ROUND(ST_Distance(
        l."coordinates",
        ST_SetSRID(ST_MakePoint(-83.5379, 41.6528), 4326)::geography
    )::numeric / 1000, 1) AS "distance_km"
FROM "location" l
WHERE l."companyId" = 'acme-corp'
ORDER BY l."coordinates" <-> ST_SetSRID(ST_MakePoint(-83.5379, 41.6528), 4326)::geography
LIMIT 1;


-- 2.4 Bounding box query: locations within a geographic rectangle
-- (Covers the greater Detroit metro area)

SELECT l."name", l."city", l."type"
FROM "location" l
WHERE l."coordinates" && ST_MakeEnvelope(-83.5, 42.2, -82.9, 42.6, 4326)::geography;


-- 2.5 Combined: RLS + PostGIS
-- Find locations within 50 km of a point, but only for companies
-- the current user has permission to view

SELECT
    l."name",
    l."city",
    c."name" AS "company",
    ROUND(ST_Distance(
        l."coordinates",
        ST_SetSRID(ST_MakePoint(-83.0458, 42.3314), 4326)::geography
    )::numeric / 1000, 1) AS "distance_km"
FROM "location" l
JOIN "company" c ON c."id" = l."companyId"
WHERE l."companyId" = ANY(get_companies_with_employee_permission('resources_view'))
  AND ST_DWithin(
    l."coordinates",
    ST_SetSRID(ST_MakePoint(-83.0458, 42.3314), 4326)::geography,
    50000
  )
ORDER BY "distance_km";


-- =========================================================================
-- PART 3: API Key Access
-- =========================================================================

-- 3.1 Simulate API key access (would be set via HTTP header in practice)
-- SET request.header.x-api-key = 'sk_live_acme_abc123def456';

-- With the API key set, all RLS functions resolve to the key's company:
SELECT get_company_id_from_api_key();
-- Expected: 'acme-corp'

-- Items accessible via API key:
SELECT "name", "partNumber"
FROM "item"
WHERE has_valid_api_key_for_company("companyId");
-- Returns only Acme items


-- =========================================================================
-- PART 4: Permission Introspection
-- =========================================================================

-- 4.1 View all permissions for a specific user
SELECT "id", "permissions"
FROM "userPermission"
WHERE "id" = 'user-bob';

-- 4.2 List all users and their roles across companies
SELECT
    u."fullName",
    u."email",
    uc."role",
    c."name" AS "company"
FROM "user" u
JOIN "userToCompany" uc ON uc."userId" = u."id"
JOIN "company" c ON c."id" = uc."companyId"
ORDER BY u."fullName", c."name";
