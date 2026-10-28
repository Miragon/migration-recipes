package com.example.orders.history;

import java.time.Instant;
import java.util.Date;
import java.util.List;
import org.camunda.bpm.engine.impl.history.event.HistoricActivityInstanceEventEntity;
import org.camunda.bpm.engine.impl.history.event.HistoricScopeInstanceEvent;
import org.camunda.bpm.engine.impl.history.event.HistoricTaskInstanceEventEntity;
import org.camunda.bpm.engine.impl.history.event.HistoryEvent;
import org.camunda.bpm.engine.impl.history.handler.HistoryEventHandler;
import org.camunda.bpm.engine.impl.util.ClockUtil;
import org.springframework.stereotype.Component;

/**
 * "Custom event exporter": receives every history event the engine produces and forwards a
 * compact envelope to an {@link EventPublisher}. Registered by {@link HistoryExportPlugin}
 * next to the default DB history handler.
 *
 * <p>MIGRATION HOTSPOTS:
 * <ul>
 *   <li>Uses internal API ({@code org.camunda.bpm.engine.impl.history.*},
 *       {@code org.camunda.bpm.engine.impl.util.ClockUtil}) - package rename only, but
 *       internal APIs are the first to change in later Operaton majors.</li>
 *   <li>{@code eventClass = event.getClass().getName()} leaks the engine package name to
 *       downstream consumers (see {@link ExportedHistoryEvent}).</li>
 *   <li>Publishes inside the engine transaction: a transaction that rolls back afterwards has
 *       already sent its events ("ghost events").</li>
 * </ul>
 *
 * <p>MIGRATION HOTSPOT (deliberate bug that already exists on Camunda 7, not caused by the
 * migration): this class is a {@code @Component} AND {@link HistoryExportPlugin} adds it to the
 * custom history event handlers. The Spring Boot starter ({@code DefaultHistoryConfiguration})
 * auto-registers a single {@code HistoryEventHandler} bean as custom history event handler by
 * itself, so the handler is registered twice and every history event is exported twice (verified
 * in this app: two "start" events per process instance). Nothing fails - the tests only check that
 * events arrive, not how often. Fix it while migrating: a bean OR a plugin registration, never both
 * (the migrated app constructs the handler inside {@code HistoryExportPlugin}).
 */
@Component
public class ExportingHistoryEventHandler implements HistoryEventHandler {

  private final EventPublisher publisher;

  public ExportingHistoryEventHandler(EventPublisher publisher) {
    this.publisher = publisher;
  }

  @Override
  public void handleEvent(HistoryEvent event) {
    publisher.publish(toEnvelope(event));
  }

  @Override
  public void handleEvents(List<HistoryEvent> events) {
    events.forEach(this::handleEvent);
  }

  ExportedHistoryEvent toEnvelope(HistoryEvent event) {
    return new ExportedHistoryEvent(
        event.getEventType(),
        event.getProcessDefinitionKey(),
        event.getProcessInstanceId(),
        activityIdOf(event),
        timestampOf(event),
        // MIGRATION HOTSPOT: org.camunda... before, org.operaton... after the migration
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
