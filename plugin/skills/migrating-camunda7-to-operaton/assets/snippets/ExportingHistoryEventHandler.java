package com.example.orders.history;

import java.time.Instant;
import java.util.Date;
import java.util.List;
import org.operaton.bpm.engine.impl.cfg.TransactionState;
import org.operaton.bpm.engine.impl.context.Context;
import org.operaton.bpm.engine.impl.history.event.HistoricActivityInstanceEventEntity;
import org.operaton.bpm.engine.impl.history.event.HistoricScopeInstanceEvent;
import org.operaton.bpm.engine.impl.history.event.HistoricTaskInstanceEventEntity;
import org.operaton.bpm.engine.impl.history.event.HistoryEvent;
import org.operaton.bpm.engine.impl.history.handler.HistoryEventHandler;
import org.operaton.bpm.engine.impl.interceptor.CommandContext;
import org.operaton.bpm.engine.impl.util.ClockUtil;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * "Custom event exporter": receives every history event the engine produces and forwards a
 * compact envelope to an {@link EventPublisher}. Created and registered by {@link HistoryExportPlugin}
 * next to the default DB history handler.
 *
 * <p>MIGRATED - no longer a Spring bean ({@code @Component} removed). The Spring Boot starter
 * registers a single {@code HistoryEventHandler} bean as custom history event handler on its own; together
 * with the plugin registration the Camunda-era version received - and exported - every event twice.
 * {@link HistoryExportPlugin#exportingHandler()} gives tests access to the registered instance.
 *
 * <p>MIGRATED - publish AFTER COMMIT (decision D9). A {@code HistoryEventHandler} runs synchronously
 * on the engine thread, inside the engine command and its database transaction. The Camunda-era
 * version published directly in {@code handleEvent}, so a transaction that rolled back afterwards
 * (failing delegate, optimistic locking, an outer Spring transaction marked rollback-only) had
 * already sent "ghost" events downstream. Now the envelope is built immediately (history entities
 * are mutable) and handed to the publisher by a {@code TransactionState.COMMITTED} listener:
 * <ul>
 *   <li>rolled-back transaction: no events (see {@code ExportingHistoryEventHandlerTest});</li>
 *   <li>committed transaction: events in production order; with the Spring starter the listener is a
 *       Spring {@code TransactionSynchronization} ({@code SpringTransactionContext});</li>
 *   <li>at-most-once: a crash between commit and publish loses events. Use a transactional outbox
 *       (insert into an own table in the same transaction, relay with a poller/CDC) for at-least-once;</li>
 *   <li>never throw from the listener: the data is already committed, but the exception would still
 *       reach the API caller. A real Kafka/AMQP publisher should also hand off to an executor, because a
 *       broker outage blocks {@code send()} for up to {@code max.block.ms}.</li>
 * </ul>
 *
 * <p>Internal API ({@code org.operaton.bpm.engine.impl.*}): package rename only; identical in
 * Operaton 1.1.5 and 2.1.5. Maintainers announced a public external-history API with an outbox
 * implementation for a later release (operaton#3282).
 */
public class ExportingHistoryEventHandler implements HistoryEventHandler {

  private static final Logger LOG = LoggerFactory.getLogger(ExportingHistoryEventHandler.class);

  private final EventPublisher publisher;

  public ExportingHistoryEventHandler(EventPublisher publisher) {
    this.publisher = publisher;
  }

  @Override
  public void handleEvent(HistoryEvent event) {
    ExportedHistoryEvent envelope = toEnvelope(event);   // map NOW - the entity may change later in the tx
    CommandContext commandContext = Context.getCommandContext();
    if (commandContext == null) {
      // not inside an engine command (should not happen for engine-produced events): nothing to wait for
      publishSafely(envelope);
      return;
    }
    commandContext.getTransactionContext()
        .addTransactionListener(TransactionState.COMMITTED, committed -> publishSafely(envelope));
  }

  @Override
  public void handleEvents(List<HistoryEvent> events) {
    events.forEach(this::handleEvent);
  }

  private void publishSafely(ExportedHistoryEvent envelope) {
    try {
      publisher.publish(envelope);
    } catch (RuntimeException e) {
      // at-most-once: log and continue - an exception here would surface to the API caller
      // although the engine transaction is already committed
      LOG.warn("History export failed for {} of process instance {} (event lost)",
          envelope.eventType(), envelope.processInstanceId(), e);
    }
  }

  ExportedHistoryEvent toEnvelope(HistoryEvent event) {
    return new ExportedHistoryEvent(
        event.getEventType(),
        event.getProcessDefinitionKey(),
        event.getProcessInstanceId(),
        activityIdOf(event),
        timestampOf(event),
        // KEPT for schema compatibility (see ExportedHistoryEvent): was org.camunda.bpm.engine.impl.history.event.*,
        // is org.operaton.bpm.engine.impl.history.event.* now. New consumers should use the simple name.
        event.getClass().getName());
  }

  private static String activityIdOf(HistoryEvent event) {
    if (event instanceof HistoricActivityInstanceEventEntity activity) {
      return activity.getActivityId();
    }
    if (event instanceof HistoricTaskInstanceEventEntity task) {
      return task.getTaskDefinitionKey();
    }
    return null;
  }

  private static Instant timestampOf(HistoryEvent event) {
    if (event instanceof HistoricScopeInstanceEvent scope) {
      Date date = scope.getEndTime() != null ? scope.getEndTime() : scope.getStartTime();
      if (date != null) {
        return date.toInstant();
      }
    }
    return ClockUtil.getCurrentTime().toInstant();
  }
}
