package com.example.orders.incident;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import org.operaton.bpm.engine.impl.incident.DefaultIncidentHandler;
import org.operaton.bpm.engine.impl.incident.IncidentContext;
import org.operaton.bpm.engine.runtime.Incident;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Replaces the default "failedJob" incident handler: creates the incident as usual and then
 * notifies operations (here: log + in-memory list; in real life e-mail/Slack/PagerDuty).
 *
 * <p>MIGRATED: extends the internal {@code org.operaton.bpm.engine.impl.incident} API (package
 * rename only, identical in Operaton 1.1.5 and 2.1.5) and is registered through
 * {@code setCustomIncidentHandlers} in {@link IncidentNotificationPlugin}. The incident type
 * ("failedJob") is persisted data and stays unchanged. Alert rules keyed on logger names must
 * use {@code org.operaton.bpm...}; rules keyed on message codes (ENGINE-xxxxx) keep working.
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
