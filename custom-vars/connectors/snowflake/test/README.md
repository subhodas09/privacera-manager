# Snowflake PolicySync configuration (`test`)

This directory configures the Privacera Snowflake connector for the `test`
connector instance. Its Snowflake objects are:

| Object | Name |
|---|---|
| Service role | `PRIVACERA_POLICYSYNC_ROLE` |
| Warehouse | `PRIVACERA_POLICYSYNC_WH` |
| Database | `PRIVACERA_DB` |
| Service user | `PRIVACERA_POLICYSYNC_USER` |
| JDBC host | `kbgsygr-cs63822.snowflakecomputing.com` |

## 1. Create the Snowflake prerequisites

Sign in to Snowsight with a user that can use `ACCOUNTADMIN`, open a worksheet,
and run [`snowflake-prerequisites.sql`](snowflake-prerequisites.sql). The script
is safe to re-run: it uses `IF NOT EXISTS`, reconciles mutable settings, and
does not drop objects.

The role intentionally has powerful account-level permissions because
PolicySync must create/manage roles and users, apply masking policies, and
manage grants. Treat the service user as a privileged automation identity; do
not use it for interactive analyst work.

The warehouse is `XSMALL`, auto-resumes, and suspends after 600 seconds. It has
one cluster and omits `SCALING_POLICY`, as required for this exercise. That
keeps development cost bounded while still allowing PolicySync jobs to start
without manual warehouse operations.

`IMPORTED PRIVILEGES` on the shared `SNOWFLAKE` database permits audit reads
such as `ACCOUNT_USAGE`; it does not grant access to application databases.
`PRIVACERA_DB` is reserved for Privacera security functions.

### Free-trial row access limitation

The final `GRANT APPLY ROW ACCESS POLICY` statement can fail with Snowflake
error `391811` on a free-trial account. Run it separately as the script does.
The rest of the prerequisite setup remains usable, but row-access-policy
management is unavailable until the account edition supports it.

## 2. Set the service-user password privately

Open [`snowflake-user-password.sql.example`](snowflake-user-password.sql.example),
copy its statement into a **private** Snowsight worksheet, replace the
placeholder with a generated unique password, and execute it. Do not save or
commit the rendered SQL.

Store that exact password as the GitHub Actions repository secret
`SNOWFLAKE_JDBC_PASSWORD`:

1. GitHub repository **Settings** → **Secrets and variables** → **Actions**.
2. Select **New repository secret**.
3. Name it `SNOWFLAKE_JDBC_PASSWORD` and paste the Snowflake service-user
   password.
4. Add `SNOWFLAKE_DEFAULT_USER_PASSWORD` with a different strong password.
   PolicySync uses this second value only when it creates managed Snowflake
   users.

The workflow injects both values into its temporary checkout immediately
before `privacera-manager.sh setup`. Neither password belongs in
[`vars.connector.snowflake.yml`](vars.connector.snowflake.yml), logs, or Git.

## 3. Validate

Run [`snowflake-validate.sql`](snowflake-validate.sql) in Snowsight. Confirm:

- all four objects are returned;
- the service role has warehouse `USAGE` and `OPERATE`;
- the service role has imported privileges on `SNOWFLAKE` and the expected
  account-level grants;
- `SHOW GRANTS OF ROLE` shows the role assigned to
  `PRIVACERA_POLICYSYNC_USER`.

Then test the actual service identity in a fresh connection:

```sql
SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE();
SELECT 1;
```

Expected values are `PRIVACERA_POLICYSYNC_USER`,
`PRIVACERA_POLICYSYNC_ROLE`, and `PRIVACERA_POLICYSYNC_WH`.

## Connector behavior

[`vars.connector.snowflake.yml`](vars.connector.snowflake.yml) enables
PolicySync, grant updates, entity management, and Snowflake audit ingestion.
Managed resources are constrained to `PRIVACERA_DB` and
`PRIVACERA_POLICYSYNC_WH`; however, entity management currently has no prefix
filter, so Privacera may manage every Ranger user/group/role it receives. Add
`CONNECTOR_SNOWFLAKE_MANAGE_ENTITY_PREFIX` before production if the integration
must manage only namespaced identities.
