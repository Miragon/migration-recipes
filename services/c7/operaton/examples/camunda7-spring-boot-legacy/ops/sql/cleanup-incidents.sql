-- =============================================================================================
-- INTENTIONALLY NAIVE LEGACY EXAMPLE - analysed in the Camunda 7 -> Operaton migration guide.
-- Do NOT run this in production. It is the kind of script found in many ops repositories.
--
-- Problems: deleting runtime incidents behind the engine's back leaves the history
-- (ACT_HI_INCIDENT) open, breaks Cockpit statistics, does not fix the failing job
-- (it will fail again), and ignores custom IncidentHandlers that would normally be notified.
-- Use RuntimeService#resolveIncident / ManagementService#setJobRetries instead.
--
-- MIGRATION NOTE: still syntactically valid on Operaton (same ACT_* schema) - no recipe flags it.
-- The incident type values ('failedJob', 'failedExternalTask') are unchanged.
-- =============================================================================================

DELETE FROM ACT_RU_INCIDENT
 WHERE INCIDENT_TYPE_ = 'failedJob'
   AND INCIDENT_TIMESTAMP_ < CURRENT_TIMESTAMP - INTERVAL '7' DAY;
