<a id="opssql-direct-sql-replaced-by-the-engine-api-decision-d10"></a>

# ops/sql: direct SQL replaced by the engine API (direct database scripts decision, D10)

The Camunda-era scripts in this folder changed `ACT_*` rows behind the engine's back. They would still "work" on
Operaton, because the schema is identical, and no recipe flags them. That makes them dangerous: they skip what the
engine does on every change, such as optimistic locking, incident handling and the operation log.

Following the [direct database scripts decision (D10)](../../../../docs/01-migration-path-and-decisions.md#d10), the
example replaces them with the Java API or REST. The files are kept, but they now contain no executable SQL, only a
pointer to their replacement. The sections below name the problem of each script and what replaces it.

## `retry-failed-jobs.sql`

- **Problem:** no `REV_` bump, incidents left open, no operation log. The engine uses `REV_` for optimistic locking,
  so a missing bump can lose updates.
- **Replacement:** `operations/IncidentRecoveryService` (`retryJob`, `retryJobsOfDefinition`,
  `retryFailedJobsAsync`), or REST `PUT /engine-rest/job/{id}/retries` and `POST /engine-rest/job/retries`.

## `cleanup-incidents.sql`

- **Problem:** deleting incidents leaves their history open, and the job fails again because its cause is not fixed.
- **Replacement:** retry, which resolves the incident, or `IncidentRecoveryService#annotateIncident` to document it.
  Never delete incidents.

## `grant-admin.sql`

- **Problem:** it bypasses `IdentityService`, and `camunda-admin` is no admin group any more: Operaton's admin group is
  `operaton-admin`.
- **Replacement:** `migration/AdminGroupMigrationPlugin`. For single users: `PUT /engine-rest/group/operaton-admin/members/{userId}`
  or the Admin webapp.

## Emergency SQL

For when the engine API is **not** available, the starter pack has tested SQL in [`sql/`](../../../../sql/README.md):
the emergency retry scripts `30-` and `31-`, and `10-migrate-admin-group.sql` for the admin group. Use it only under
its rules: engine stopped, narrow scope, reviewed. Details: [Emergency SQL: strict rules of use](../../../../docs/08-database-schema-data-and-sql-scripts.md#emergency-sql-strict-rules-of-use).
