package com.example.orders.incident;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import org.camunda.bpm.engine.impl.incident.DefaultIncidentHandler;
import org.camunda.bpm.engine.impl.incident.IncidentContext;
import org.camunda.bpm.engine.runtime.Incident;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Replaces the default "failedJob" incident handler: creates the incident as usual and then
 * notifies operations (here: log + in-memory list; in real life e-mail/Slack/PagerDuty).
 *
 * <p>MIGRATION HOTSPOT: extends the internal {@code org.camunda.bpm.engine.impl.incident}
 * API and is registered through {@code setCustomIncidentHandlers} in
 * {@link IncidentNotificationPlugin}. Alerting rules that match on the incident message or
 * on logger names ({@code org.camunda.bpm...}) need to be revisited as well.
 */
public class NotifyingFailedJobIncidentHandler extends DefaultIncidentHandler {

  private static final Logger LOG = LoggerFactory.getLogger(NotifyingFailedJobIncidentHandler.class);

  private final List<String> notifiedIncidentIds = new CopyOnWriteArrayList<>();

  public NotifyingFailedJobIncidentHandler() {
    super(Incident.FAILED_JOB_HANDLER_TYPE);
  }

  @Override
  public Incident handleIncident(IncidentContext context, String message) {
    Incident incident = super.handleIncident(context, message);
    LOG.warn("PAGING ops: incident {} of type {} at activity {} in process instance {}: {}",
        incident.getId(), incident.getIncidentType(), context.getActivityId(),
        incident.getProcessInstanceId(), message);
    notifiedIncidentIds.add(incident.getId());
    return incident;
  }

  public List<String> notifiedIncidentIds() {
    return List.copyOf(notifiedIncidentIds);
  }
}
