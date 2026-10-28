package com.example.orders.history;

import java.time.Instant;

/**
 * Small, JSON-serialisable envelope that is handed to downstream consumers (Kafka in
 * production, {@link InMemoryEventPublisher} here).
 *
 * <p>MIGRATED - {@code eventClass} is a breaking change of the event schema (decision D9):
 * it carries the engine's Java class name, which changed from
 * {@code org.camunda.bpm.engine.impl.history.event.HistoricActivityInstanceEventEntity} to
 * {@code org.operaton.bpm.engine.impl.history.event.HistoricActivityInstanceEventEntity}. Nothing
 * fails at compile time, but consumers that route or filter on it (stream processors, SIEM rules,
 * dashboards) break silently. The field is KEPT so the JSON shape stays the same; consumers must
 * match on the simple class name / {@code eventType} and accept both prefixes while Camunda-era
 * events are still in the topics (dual read). The same trap applies to anything that
 * persists class names (Java-serialized variables, type ids in JSON, custom DB columns).
 */
public record ExportedHistoryEvent(
    String eventType,
    String processDefinitionKey,
    String processInstanceId,
    String activityId,
    Instant timestamp,
    String eventClass) {
}
