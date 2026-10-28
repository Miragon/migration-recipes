package com.example.orders.history;

import java.time.Instant;

/**
 * Small, JSON-serialisable envelope that is handed to downstream consumers (Kafka in
 * production, {@link InMemoryEventPublisher} here).
 *
 * <p>MIGRATION HOTSPOT: {@code eventClass} carries the engine's Java class name, e.g.
 * {@code org.camunda.bpm.engine.impl.history.event.HistoricActivityInstanceEventEntity}.
 * After the migration it becomes {@code org.operaton...}. Code compiles fine, but every
 * consumer that routes/filters on this field (stream processors, SIEM rules, dashboards)
 * breaks silently. The same applies to anything that persists class names (serialized
 * Java variables, custom DB columns, ...).
 */
public record ExportedHistoryEvent(
    String eventType,
    String processDefinitionKey,
    String processInstanceId,
    String activityId,
    Instant timestamp,
    String eventClass) {
}
