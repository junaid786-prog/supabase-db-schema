-- =============================================================================
-- Row Level Security: Helper Functions & Policies
-- =============================================================================
-- This file implements the complete RLS layer for multi-tenant isolation.
--
-- Strategy:
--   1. Centralized SECURITY DEFINER functions resolve the current user's
--      companies and permissions once, then RLS policies reference them.
--   2. Every tenant-scoped table gets four policies: SELECT, INSERT, UPDATE, DELETE.
--   3. API key access provides an alternative auth path for M2M integrations.
-- =============================================================================

-- =============================================================================
-- SECTION 1: Utility Functions
-- =============================================================================

-- Convert JSONB array to text array
CREATE OR REPLACE FUNCTION jsonb_to_text_array(jsonb)
RETURNS text[]
LANGUAGE sql IMMUTABLE
AS $$
    SELECT array_agg(value::text) FROM jsonb_array_elements_text($1) AS t(value);
$$;

-- =============================================================================
-- SECTION 2: API Key Resolution
-- =============================================================================

-- Extract company ID from the API key passed in request headers
CREATE OR REPLACE FUNCTION get_company_id_from_api_key()
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    company_id TEXT;
BEGIN
    SELECT "companyId" INTO company_id
    FROM "apiKey"
    WHERE "key" = (
        (current_setting('request.headers'::text, true))::json ->> 'x-api-key'
    );
    RETURN company_id;
END;
$$;

-- Check if current request has a valid API key for a specific company
CREATE OR REPLACE FUNCTION has_valid_api_key_for_company(company TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
    RETURN EXISTS(
        SELECT 1 FROM "apiKey"
        WHERE "key" = (
            (current_setting('request.headers'::text, true))::json ->> 'x-api-key'
        )
        AND "companyId" = company
    );
END;
$$;

-- =============================================================================
-- SECTION 3: Role & Permission Resolution Functions
-- =============================================================================

-- Get all companies where the current user has any role
CREATE OR REPLACE FUNCTION get_companies_with_any_role()
RETURNS text[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    user_companies text[];
    api_key_company text;
BEGIN
    -- API key path: return the single company associated with the key
    api_key_company := get_company_id_from_api_key();
    IF api_key_company IS NOT NULL THEN
        RETURN ARRAY[api_key_company];
    END IF;

    -- User session path: return all companies
    SELECT array_agg("companyId"::text)
    INTO user_companies
    FROM "userToCompany"
    WHERE "userId" = (SELECT auth.uid())::text;

    RETURN user_companies;
END;
$$;

-- Get companies where the current user is specifically an employee
CREATE OR REPLACE FUNCTION get_companies_with_employee_role()
RETURNS text[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    user_companies text[];
    api_key_company text;
BEGIN
    api_key_company := get_company_id_from_api_key();
    IF api_key_company IS NOT NULL THEN
        RETURN ARRAY[api_key_company];
    END IF;

    SELECT array_agg("companyId"::text)
    INTO user_companies
    FROM "userToCompany"
    WHERE "userId" = (SELECT auth.uid())::text
      AND "role" = 'employee';

    RETURN user_companies;
END;
$$;

-- Get companies where the user is an employee AND has a specific permission
-- This is the core function used by most RLS policies.
CREATE OR REPLACE FUNCTION get_companies_with_employee_permission(permission text)
RETURNS text[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    permission_companies text[];
    api_key_company text;
    employee_companies text[];
BEGIN
    -- API key bypass
    api_key_company := get_company_id_from_api_key();
    IF api_key_company IS NOT NULL THEN
        RETURN ARRAY[api_key_company];
    END IF;

    -- Get companies where user is an employee
    SELECT array_agg("companyId"::text)
    INTO employee_companies
    FROM "userToCompany"
    WHERE "userId" = (SELECT auth.uid())::text
      AND "role" = 'employee';

    -- Get companies from user's permission map
    SELECT jsonb_to_text_array(COALESCE(permissions->permission, '[]'))
    INTO permission_companies
    FROM public."userPermission"
    WHERE id::text = (SELECT auth.uid())::text;

    -- Intersect: only companies where user is BOTH employee AND has permission
    IF permission_companies IS NOT NULL AND employee_companies IS NOT NULL THEN
        SELECT array_agg(company)
        INTO permission_companies
        FROM unnest(permission_companies) company
        WHERE company = ANY(employee_companies);
    ELSE
        permission_companies := '{}';
    END IF;

    -- Handle global permission: "0" means all companies where user is employee
    IF permission_companies IS NOT NULL AND '0'::text = ANY(permission_companies) THEN
        SELECT array_agg(id::text)
        INTO permission_companies
        FROM company
        WHERE id::text = ANY(employee_companies);
    END IF;

    RETURN permission_companies;
END;
$$;

-- Get customer IDs accessible to the current user (for customer-role users)
CREATE OR REPLACE FUNCTION get_customer_ids_with_customer_permission(permission text)
RETURNS text[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    permission_companies text[];
    customer_company_ids text[];
    customer_ids text[];
BEGIN
    SELECT array_agg("companyId"::text)
    INTO customer_company_ids
    FROM "userToCompany"
    WHERE "userId" = (SELECT auth.uid())::text
      AND "role" = 'customer';

    SELECT jsonb_to_text_array(COALESCE(permissions->permission, '[]'))
    INTO permission_companies
    FROM public."userPermission"
    WHERE id::text = (SELECT auth.uid())::text;

    IF permission_companies IS NOT NULL AND customer_company_ids IS NOT NULL THEN
        SELECT array_agg(company)
        INTO permission_companies
        FROM unnest(permission_companies) company
        WHERE company = ANY(customer_company_ids);
    ELSE
        permission_companies := '{}';
    END IF;

    RETURN permission_companies;
END;
$$;

-- Get supplier IDs accessible to the current user (for supplier-role users)
CREATE OR REPLACE FUNCTION get_supplier_ids_with_supplier_permission(permission text)
RETURNS text[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    permission_companies text[];
    supplier_company_ids text[];
BEGIN
    SELECT array_agg("companyId"::text)
    INTO supplier_company_ids
    FROM "userToCompany"
    WHERE "userId" = (SELECT auth.uid())::text
      AND "role" = 'supplier';

    SELECT jsonb_to_text_array(COALESCE(permissions->permission, '[]'))
    INTO permission_companies
    FROM public."userPermission"
    WHERE id::text = (SELECT auth.uid())::text;

    IF permission_companies IS NOT NULL AND supplier_company_ids IS NOT NULL THEN
        SELECT array_agg(company)
        INTO permission_companies
        FROM unnest(permission_companies) company
        WHERE company = ANY(supplier_company_ids);
    ELSE
        permission_companies := '{}';
    END IF;

    RETURN permission_companies;
END;
$$;

-- Resolve companyId from a foreign key on another table
CREATE OR REPLACE FUNCTION get_company_id_from_foreign_key(foreign_key TEXT, tbl TEXT)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    company_id text;
BEGIN
    EXECUTE 'SELECT "companyId" FROM "' || tbl || '" WHERE id = $1'
    INTO company_id USING foreign_key;
    RETURN company_id;
END;
$$;

-- =============================================================================
-- SECTION 4: Enable RLS on All Tables
-- =============================================================================

ALTER TABLE "user"           ENABLE ROW LEVEL SECURITY;
ALTER TABLE "company"        ENABLE ROW LEVEL SECURITY;
ALTER TABLE "userToCompany"  ENABLE ROW LEVEL SECURITY;
ALTER TABLE "userPermission" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "employeeType"   ENABLE ROW LEVEL SECURITY;
ALTER TABLE "employee"       ENABLE ROW LEVEL SECURITY;
ALTER TABLE "apiKey"         ENABLE ROW LEVEL SECURITY;
ALTER TABLE "item"           ENABLE ROW LEVEL SECURITY;
ALTER TABLE "location"       ENABLE ROW LEVEL SECURITY;

-- =============================================================================
-- SECTION 5: Core Table Policies
-- =============================================================================

-- ---- user ----

CREATE POLICY "Users can view users in their companies" ON "user"
FOR SELECT USING (
    "id" IN (
        SELECT "userId" FROM "userToCompany"
        WHERE "companyId" IN (
            SELECT "companyId" FROM "userToCompany"
            WHERE "userId" = (SELECT auth.uid())::text
        )
    )
);

CREATE POLICY "Users can update themselves" ON "user"
FOR UPDATE WITH CHECK (
    (SELECT auth.uid()) = id::uuid
);

-- ---- company ----

CREATE POLICY "SELECT" ON "company"
FOR SELECT USING (
    "id" = ANY(get_companies_with_any_role())
);

CREATE POLICY "INSERT" ON "company"
FOR INSERT WITH CHECK (
    "id" = ANY(get_companies_with_employee_permission('settings_create'))
);

CREATE POLICY "UPDATE" ON "company"
FOR UPDATE USING (
    "id" = ANY(get_companies_with_employee_permission('settings_update'))
);

CREATE POLICY "DELETE" ON "company"
FOR DELETE USING (
    "id" = ANY(get_companies_with_employee_permission('settings_delete'))
);

-- ---- userToCompany ----

CREATE POLICY "SELECT" ON "userToCompany"
FOR SELECT USING (
    (SELECT auth.role()) = 'authenticated'
);

CREATE POLICY "INSERT" ON "userToCompany"
FOR INSERT WITH CHECK (
    "companyId" = ANY(get_companies_with_employee_permission('users_create'))
);

CREATE POLICY "UPDATE" ON "userToCompany"
FOR UPDATE USING (
    "companyId" = ANY(get_companies_with_employee_permission('users_update'))
);

CREATE POLICY "DELETE" ON "userToCompany"
FOR DELETE USING (
    "companyId" = ANY(get_companies_with_employee_permission('users_delete'))
);

-- ---- userPermission ----

CREATE POLICY "Users can view permissions in their companies" ON "userPermission"
FOR SELECT USING (
    "id" IN (
        SELECT "userId" FROM "userToCompany"
        WHERE "companyId" IN (
            SELECT "companyId" FROM "userToCompany"
            WHERE "userId" = (SELECT auth.uid())::text
        )
    )
);

-- ---- employeeType ----

CREATE POLICY "SELECT" ON "employeeType"
FOR SELECT USING (
    "companyId" = ANY(get_companies_with_any_role())
);

CREATE POLICY "INSERT" ON "employeeType"
FOR INSERT WITH CHECK (
    "companyId" = ANY(get_companies_with_employee_permission('users_create'))
);

CREATE POLICY "UPDATE" ON "employeeType"
FOR UPDATE USING (
    "companyId" = ANY(get_companies_with_employee_permission('users_update'))
);

CREATE POLICY "DELETE" ON "employeeType"
FOR DELETE USING (
    "companyId" = ANY(get_companies_with_employee_permission('users_delete'))
);

-- ---- employee ----

CREATE POLICY "SELECT" ON "employee"
FOR SELECT USING (
    "companyId" = ANY(get_companies_with_any_role())
);

CREATE POLICY "INSERT" ON "employee"
FOR INSERT WITH CHECK (
    "companyId" = ANY(get_companies_with_employee_permission('users_create'))
);

CREATE POLICY "UPDATE" ON "employee"
FOR UPDATE USING (
    "companyId" = ANY(get_companies_with_employee_permission('users_update'))
);

CREATE POLICY "DELETE" ON "employee"
FOR DELETE USING (
    "companyId" = ANY(get_companies_with_employee_permission('users_delete'))
);

-- ---- apiKey ----

CREATE POLICY "SELECT" ON "apiKey"
FOR SELECT USING (
    "companyId" = ANY(get_companies_with_employee_permission('settings_view'))
);

CREATE POLICY "INSERT" ON "apiKey"
FOR INSERT WITH CHECK (
    "companyId" = ANY(get_companies_with_employee_permission('settings_create'))
);

CREATE POLICY "UPDATE" ON "apiKey"
FOR UPDATE USING (
    "companyId" = ANY(get_companies_with_employee_permission('settings_update'))
);

CREATE POLICY "DELETE" ON "apiKey"
FOR DELETE USING (
    "companyId" = ANY(get_companies_with_employee_permission('settings_delete'))
);

-- =============================================================================
-- SECTION 6: Business Table Policies
-- =============================================================================

-- ---- item (inventory) ----

CREATE POLICY "SELECT" ON "item"
FOR SELECT USING (
    "companyId" = ANY(get_companies_with_employee_permission('inventory_view'))
);

CREATE POLICY "INSERT" ON "item"
FOR INSERT WITH CHECK (
    "companyId" = ANY(get_companies_with_employee_permission('inventory_create'))
);

CREATE POLICY "UPDATE" ON "item"
FOR UPDATE USING (
    "companyId" = ANY(get_companies_with_employee_permission('inventory_update'))
);

CREATE POLICY "DELETE" ON "item"
FOR DELETE USING (
    "companyId" = ANY(get_companies_with_employee_permission('inventory_delete'))
);

-- API key access for items
CREATE POLICY "API key access" ON "item"
FOR ALL USING (
    has_valid_api_key_for_company("companyId")
);

-- ---- location (PostGIS) ----

CREATE POLICY "SELECT" ON "location"
FOR SELECT USING (
    "companyId" = ANY(get_companies_with_employee_permission('resources_view'))
);

CREATE POLICY "INSERT" ON "location"
FOR INSERT WITH CHECK (
    "companyId" = ANY(get_companies_with_employee_permission('resources_create'))
);

CREATE POLICY "UPDATE" ON "location"
FOR UPDATE USING (
    "companyId" = ANY(get_companies_with_employee_permission('resources_update'))
);

CREATE POLICY "DELETE" ON "location"
FOR DELETE USING (
    "companyId" = ANY(get_companies_with_employee_permission('resources_delete'))
);

CREATE POLICY "API key access" ON "location"
FOR ALL USING (
    has_valid_api_key_for_company("companyId")
);
