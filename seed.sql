-- =============================================================================
-- Seed Data: Multi-Tenant Demo
-- =============================================================================
-- Two companies (tenants) with users in different roles and permissions.
-- Includes PostGIS location data for spatial query demonstrations.
-- =============================================================================

-- ---- Companies (Tenants) ----

INSERT INTO "company" ("id", "name", "taxId", "city", "state", "countryCode") VALUES
    ('acme-corp',   'Acme Manufacturing',   '12-3456789', 'Detroit',     'MI', 'US'),
    ('bolt-mfg',    'Bolt Precision Works', '98-7654321', 'Pittsburgh',  'PA', 'US');

-- ---- Users ----

INSERT INTO "user" ("id", "email", "firstName", "lastName") VALUES
    ('user-alice',   'alice@acme.com',       'Alice',   'Chen'),
    ('user-bob',     'bob@acme.com',         'Bob',     'Martinez'),
    ('user-carol',   'carol@bolt.com',       'Carol',   'Davis'),
    ('user-dave',    'dave@external.com',    'Dave',    'Wilson'),
    ('user-system',  'system@app.internal',  'System',  'Operation');

-- ---- Employee Types ----

INSERT INTO "employeeType" ("id", "name", "companyId", "protected") VALUES
    ('et-acme-admin',    'Admin',              'acme-corp', TRUE),
    ('et-acme-operator', 'Floor Operator',     'acme-corp', FALSE),
    ('et-bolt-admin',    'Admin',              'bolt-mfg',  TRUE),
    ('et-bolt-engineer', 'Process Engineer',   'bolt-mfg',  FALSE);

-- ---- Tenant Membership ----
-- Alice: admin at Acme
-- Bob: floor operator at Acme
-- Carol: admin at Bolt
-- Dave: customer at Acme, supplier at Bolt (cross-tenant external user)

INSERT INTO "userToCompany" ("userId", "companyId", "role") VALUES
    ('user-alice',  'acme-corp',  'employee'),
    ('user-bob',    'acme-corp',  'employee'),
    ('user-carol',  'bolt-mfg',   'employee'),
    ('user-dave',   'acme-corp',  'customer'),
    ('user-dave',   'bolt-mfg',   'supplier');

-- ---- Employees ----

INSERT INTO "employee" ("id", "companyId", "employeeTypeId") VALUES
    ('user-alice',  'acme-corp',  'et-acme-admin'),
    ('user-bob',    'acme-corp',  'et-acme-operator'),
    ('user-carol',  'bolt-mfg',   'et-bolt-admin');

-- ---- Permissions ----
-- Alice: full admin at Acme (global "0" = all companies she's employee of)
-- Bob: can view inventory and resources at Acme only
-- Carol: full admin at Bolt
-- Dave: limited view access as customer/supplier

INSERT INTO "userPermission" ("id", "permissions") VALUES
    ('user-alice', '{
        "settings_view":      ["0"],
        "settings_create":    ["0"],
        "settings_update":    ["0"],
        "settings_delete":    ["0"],
        "users_view":         ["0"],
        "users_create":       ["0"],
        "users_update":       ["0"],
        "users_delete":       ["0"],
        "inventory_view":     ["0"],
        "inventory_create":   ["0"],
        "inventory_update":   ["0"],
        "inventory_delete":   ["0"],
        "resources_view":     ["0"],
        "resources_create":   ["0"],
        "resources_update":   ["0"],
        "resources_delete":   ["0"],
        "purchasing_view":    ["0"],
        "purchasing_create":  ["0"]
    }'::jsonb),

    ('user-bob', '{
        "inventory_view":     ["acme-corp"],
        "resources_view":     ["acme-corp"]
    }'::jsonb),

    ('user-carol', '{
        "settings_view":      ["0"],
        "settings_create":    ["0"],
        "settings_update":    ["0"],
        "settings_delete":    ["0"],
        "users_view":         ["0"],
        "users_create":       ["0"],
        "users_update":       ["0"],
        "users_delete":       ["0"],
        "inventory_view":     ["0"],
        "inventory_create":   ["0"],
        "inventory_update":   ["0"],
        "inventory_delete":   ["0"],
        "resources_view":     ["0"],
        "resources_create":   ["0"],
        "resources_update":   ["0"],
        "resources_delete":   ["0"]
    }'::jsonb),

    ('user-dave', '{
        "purchasing_view":    ["acme-corp", "bolt-mfg"]
    }'::jsonb);

-- ---- API Key ----

INSERT INTO "apiKey" ("id", "name", "key", "companyId", "createdBy") VALUES
    ('key-acme-erp', 'ERP Integration', 'sk_live_acme_abc123def456', 'acme-corp', 'user-alice');

-- ---- Inventory Items ----

INSERT INTO "item" ("id", "companyId", "name", "description", "partNumber", "unitOfMeasure") VALUES
    ('item-001', 'acme-corp', 'Steel Rod 1/2"',        '0.5 inch cold-rolled steel rod',    'SR-0500', 'feet'),
    ('item-002', 'acme-corp', 'Aluminum Sheet 4x8',     '4ft x 8ft 0.063" aluminum sheet',   'AS-4863', 'sheet'),
    ('item-003', 'acme-corp', 'Hex Bolt M10x40',        'Grade 8.8 hex bolt',                'HB-1040', 'each'),
    ('item-004', 'bolt-mfg',  'Titanium Bar 1"',        '1 inch Grade 5 titanium bar',       'TB-1000', 'feet'),
    ('item-005', 'bolt-mfg',  'Stainless Sheet 4x8',    '4ft x 8ft 304 stainless sheet',     'SS-4804', 'sheet');

-- ---- Locations (PostGIS) ----
-- Real-world coordinates for spatial query demonstrations

INSERT INTO "location" ("id", "companyId", "name", "type", "city", "state", "coordinates") VALUES
    -- Acme locations (Detroit area)
    ('loc-001', 'acme-corp', 'Main Plant',         'factory',    'Detroit',        'MI',
        ST_SetSRID(ST_MakePoint(-83.0458, 42.3314), 4326)::geography),
    ('loc-002', 'acme-corp', 'North Warehouse',    'warehouse',  'Warren',         'MI',
        ST_SetSRID(ST_MakePoint(-83.0293, 42.4775), 4326)::geography),
    ('loc-003', 'acme-corp', 'South Distribution', 'warehouse',  'Dearborn',       'MI',
        ST_SetSRID(ST_MakePoint(-83.1763, 42.3223), 4326)::geography),

    -- Bolt locations (Pittsburgh area)
    ('loc-004', 'bolt-mfg',  'Precision Shop',     'factory',    'Pittsburgh',     'PA',
        ST_SetSRID(ST_MakePoint(-79.9959, 40.4406), 4326)::geography),
    ('loc-005', 'bolt-mfg',  'East Storage',       'warehouse',  'Monroeville',    'PA',
        ST_SetSRID(ST_MakePoint(-79.7881, 40.4212), 4326)::geography);
