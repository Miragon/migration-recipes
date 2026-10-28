-- =============================================================================================
-- INTENTIONALLY NAIVE LEGACY EXAMPLE - analysed in the Camunda 7 -> Operaton migration guide.
-- Do NOT run this in production. It is the kind of script found in many ops repositories.
--
-- Problems (independent of the migration): bypasses the engine API, ignores optimistic locking
-- (REV_), leaves incidents (ACT_RU_INCIDENT) open, does not reset lock owner/expiry consistently
-- and writes no user operation log. Use ManagementService#setJobRetries / the REST API
-- (/engine-rest/job/retries) or Cockpit batch operations instead.
--
-- MIGRATION NOTE: the ACT_* schema is identical in Operaton, so this script keeps "working"
-- after the migration - no recipe will ever flag it. Review it anyway.
-- =============================================================================================

-- "Retry everything that failed"
UPDATE ACT_RU_JOB
   SET RETRIES_ = 3,
       EXCEPTION_STACK_ID_ = NULL,
       EXCEPTION_MSG_ = NULL,
       DUEDATE_ = CURRENT_TIMESTAMP
 WHERE RETRIES_ = 0
   AND HANDLER_TYPE_ = 'async-continuation';
