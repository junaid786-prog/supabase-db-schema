-- =============================================================================
-- Multi-Tenant Schema with PostGIS
-- =============================================================================
-- This schema implements a multi-tenant architecture where each "company" is
-- an isolated tenant. Users can belong to multiple tenants with different roles.
-- =============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "postgis";

-- =============================================================================
-- 1. Core Identity Tables
-- =============================================================================

CREATE TABLE "user" (
    "id" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "firstName" TEXT NOT NULL,
    "lastName" TEXT NOT NULL,
    "fullName" TEXT GENERATED ALWAYS AS ("firstName" || ' ' || "lastName") STORED,
    "avatarUrl" TEXT,
    "active" BOOLEAN DEFAULT TRUE,
    "createdAt" TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    "updatedAt" TIMESTAMPTZ,

    CONSTRAINT "user_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "idx_user_email" ON "user"("email");
CREATE INDEX "idx_user_fullName" ON "user"("fullName");

-- =============================================================================
-- 2. Tenant (Company) Table
-- =============================================================================

CREATE TABLE "company" (
    "id" TEXT NOT NULL DEFAULT uuid_generate_v4()::text,
    "name" TEXT NOT NULL,
    "taxId" TEXT,
    "logo" TEXT,
    "addressLine1" TEXT,
    "addressLine2" TEXT,
    "city" TEXT,
    "state" TEXT,
    "postalCode" TEXT,
    "countryCode" TEXT,
    "phone" TEXT,
    "email" TEXT,
    "website" TEXT,
    "createdAt" TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    "updatedAt" TIMESTAMPTZ,

    CONSTRAINT "company_pkey" PRIMARY KEY ("id")
);

-- =============================================================================
-- 3. Tenant Membership (User <-> Company with Role)
-- =============================================================================

CREATE TYPE "role" AS ENUM ('employee', 'customer', 'supplier');

CREATE TABLE "userToCompany" (
    "userId" TEXT NOT NULL REFERENCES "user"("id") ON UPDATE CASCADE ON DELETE CASCADE,
    "companyId" TEXT NOT NULL REFERENCES "company"("id") ON UPDATE CASCADE ON DELETE CASCADE,
    "role" "role" NOT NULL,

    CONSTRAINT "userToCompany_pkey" PRIMARY KEY ("userId", "companyId")
);

CREATE INDEX "idx_userToCompany_companyId" ON "userToCompany"("companyId");

-- =============================================================================
-- 4. Permission System
-- =============================================================================
-- Permissions are stored as JSONB: { "module_action": ["companyId1", "companyId2"] }
-- A value of ["0"] means "all companies" (superadmin for that permission).

CREATE TABLE "userPermission" (
    "id" TEXT NOT NULL,
    "permissions" JSONB DEFAULT '{}',

    CONSTRAINT "userPermission_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "userPermission_id_fkey" FOREIGN KEY ("id")
        REFERENCES "user"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

-- Employee types allow grouping permissions by role template
CREATE TABLE "employeeType" (
    "id" TEXT NOT NULL DEFAULT uuid_generate_v4()::text,
    "name" TEXT NOT NULL,
    "companyId" TEXT NOT NULL,
    "protected" BOOLEAN NOT NULL DEFAULT FALSE,
    "createdAt" TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    "updatedAt" TIMESTAMPTZ,

    CONSTRAINT "employeeType_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "employeeType_companyId_fkey" FOREIGN KEY ("companyId")
        REFERENCES "company"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE "employee" (
    "id" TEXT NOT NULL,
    "companyId" TEXT NOT NULL,
    "employeeTypeId" TEXT NOT NULL,

    CONSTRAINT "employee_pkey" PRIMARY KEY ("id", "companyId"),
    CONSTRAINT "employee_companyId_fkey" FOREIGN KEY ("companyId")
        REFERENCES "company"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT "employee_employeeTypeId_fkey" FOREIGN KEY ("employeeTypeId")
        REFERENCES "employeeType"("id") ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE INDEX "idx_employee_companyId" ON "employee"("companyId");

-- =============================================================================
-- 5. API Key Table (Machine-to-Machine Access)
-- =============================================================================

CREATE TABLE "apiKey" (
    "id" TEXT NOT NULL DEFAULT uuid_generate_v4()::text,
    "name" TEXT NOT NULL,
    "key" TEXT NOT NULL,
    "companyId" TEXT NOT NULL,
    "createdBy" TEXT NOT NULL,
    "createdAt" TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT "apiKey_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "apiKey_key_unique" UNIQUE ("key"),
    CONSTRAINT "apiKey_name_companyId_unique" UNIQUE ("name", "companyId"),
    CONSTRAINT "apiKey_companyId_fkey" FOREIGN KEY ("companyId")
        REFERENCES "company"("id") ON DELETE CASCADE,
    CONSTRAINT "apiKey_createdBy_fkey" FOREIGN KEY ("createdBy")
        REFERENCES "user"("id") ON DELETE CASCADE
);

-- =============================================================================
-- 6. Sample Tenant-Scoped Business Tables
-- =============================================================================

-- Inventory items scoped to a tenant
CREATE TABLE "item" (
    "id" TEXT NOT NULL DEFAULT uuid_generate_v4()::text,
    "companyId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "description" TEXT,
    "partNumber" TEXT,
    "unitOfMeasure" TEXT NOT NULL DEFAULT 'each',
    "active" BOOLEAN NOT NULL DEFAULT TRUE,
    "createdAt" TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    "updatedAt" TIMESTAMPTZ,

    CONSTRAINT "item_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "item_companyId_fkey" FOREIGN KEY ("companyId")
        REFERENCES "company"("id") ON DELETE CASCADE
);

CREATE INDEX "idx_item_companyId" ON "item"("companyId");

-- =============================================================================
-- 7. PostGIS Location Table
-- =============================================================================
-- Stores physical locations (warehouses, offices, job sites) with spatial data.
-- Uses geography type for accurate distance calculations in meters.

CREATE TABLE "location" (
    "id" TEXT NOT NULL DEFAULT uuid_generate_v4()::text,
    "companyId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "type" TEXT NOT NULL DEFAULT 'warehouse',
    "addressLine1" TEXT,
    "city" TEXT,
    "state" TEXT,
    "postalCode" TEXT,
    "countryCode" TEXT DEFAULT 'US',
    "coordinates" geography(Point, 4326),
    "active" BOOLEAN NOT NULL DEFAULT TRUE,
    "createdAt" TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    "updatedAt" TIMESTAMPTZ,

    CONSTRAINT "location_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "location_companyId_fkey" FOREIGN KEY ("companyId")
        REFERENCES "company"("id") ON DELETE CASCADE
);

CREATE INDEX "idx_location_companyId" ON "location"("companyId");
CREATE INDEX "idx_location_coordinates" ON "location" USING GIST ("coordinates");

-- =============================================================================
-- 8. Convenience View
-- =============================================================================

CREATE OR REPLACE VIEW "companies" AS
SELECT DISTINCT
    c.*,
    uc."userId",
    uc."role",
    et."name" AS "employeeType"
FROM "userToCompany" uc
INNER JOIN "company" c ON c."id" = uc."companyId"
LEFT JOIN "employee" e ON e."id" = uc."userId" AND e."companyId" = uc."companyId"
LEFT JOIN "employeeType" et ON et."id" = e."employeeTypeId";
