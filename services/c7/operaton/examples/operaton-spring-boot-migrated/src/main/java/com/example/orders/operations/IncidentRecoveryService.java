package com.example.orders.operations;

import java.util.Date;
import java.util.List;
import org.operaton.bpm.engine.ExternalTaskService;
import org.operaton.bpm.engine.ManagementService;
import org.operaton.bpm.engine.ProcessEngine;
import org.operaton.bpm.engine.RuntimeService;
import org.operaton.bpm.engine.batch.Batch;
import org.operaton.bpm.engine.externaltask.ExternalTaskQuery;
import org.operaton.bpm.engine.impl.util.ClockUtil;
import org.operaton.bpm.engine.runtime.Incident;
import org.operaton.bpm.engine.runtime.JobQuery;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * The Java API replacement for the direct SQL in {@code ops/sql/} (decision D10).
 *
 * <p>The legacy scripts updated {@code ACT_RU_JOB} / deleted {@code ACT_RU_INCIDENT} rows behind the
 * engine's back: no optimistic locking ({@code REV_}), incidents left open or deleted without history,
 * custom {@code IncidentHandler}s not called, no user operation log. The schema is identical in
 * Operaton, so those scripts kept "working" after the migration and no recipe flags them. Use these
 * methods (or the equivalent REST endpoints / Cockpit batch operations) instead:
 *
 * <table>
 *   <caption>Legacy script to API</caption>
 *   <tr><th>legacy SQL</th><th>replacement</th><th>REST</th></tr>
 *   <tr><td>{@code UPDATE ACT_RU_JOB SET RETRIES_=3 ...} (one job)</td><td>{@link #retryJob}</td>
 *       <td>{@code PUT /job/{id}/retries}</td></tr>
 *   <tr><td>same, all jobs of one service task</td><td>{@link #retryJobsOfDefinition}</td>
 *       <td>{@code PUT /job-definition/{id}/retries}</td></tr>
 *   <tr><td>same, "retry everything that failed"</td><td>{@link #retryFailedJobsAsync} (batch)</td>
 *       <td>{@code POST /job/retries}</td></tr>
 *   <tr><td>{@code UPDATE ACT_RU_EXT_TASK SET RETRIES_=...}</td><td>{@link #retryExternalTask},
 *       {@link #retryFailedExternalTasksAsync}</td><td>{@code PUT /external-task/{id}/retries},
 *       {@code POST /external-task/retries-async}</td></tr>
 *   <tr><td>{@code DELETE FROM ACT_RU_INCIDENT ...}</td><td>retry (resolves the incident) or
 *       {@link #annotateIncident} for the ops trail; never delete</td>
 *       <td>{@code PUT /incident/{id}/annotation}</td></tr>
 * </table>
 *
 * <p>Setting retries &gt; 0 on a failed job (by id or as batch) or external task resolves its
 * {@code failedJob} / {@code failedExternalTask} incident (with history and user operation log); the
 * job-definition variant is a bulk update that leaves incidents open until the jobs succeed. The tested emergency SQL
 * of the starter pack ({@code sql/postgresql/30-...}, {@code 31-...}) is only for when the API is not
 * available. Generic: copy into any Operaton application (only engine API + Spring {@code @Service}).
 */
@Service
public class IncidentRecoveryService {

  private static final Logger LOG = LoggerFactory.getLogger(IncidentRecoveryService.class);

  private final ManagementService managementService;
  private final ExternalTaskService externalTaskService;
  private final RuntimeService runtimeService;

  public IncidentRecoveryService(ProcessEngine processEngine) {
    this.managementService = processEngine.getManagementService();
    this.externalTaskService = processEngine.getExternalTaskService();
    this.runtimeService = processEngine.getRuntimeService();
  }

  /** Retries one job now: sets retries and moves the due date to "now" (the retry cycle had pushed it out). */
  public void retryJob(String jobId, int retries) {
    requirePositive(retries);
    managementService.setJobRetries(retries).jobId(jobId).dueDate(now()).execute();
    LOG.info("Job {}: retries set to {}, due now", jobId, retries);
  }

  /**
   * Retries all failed jobs of one job definition (e.g. one asyncBefore service task). The engine does
   * this with one bulk UPDATE: the {@code failedJob} incidents stay open until each job has run
   * successfully (verified with Operaton 2.1.5). Use {@link #retryFailedJobsAsync} if the incidents must
   * be resolved right away.
   */
  public void retryJobsOfDefinition(String jobDefinitionId, int retries) {
    requirePositive(retries);
    managementService.setJobRetries(retries).jobDefinitionId(jobDefinitionId).dueDate(now()).execute();
    LOG.info("Jobs of definition {}: retries set to {}, due now", jobDefinitionId, retries);
  }

  /**
   * "Retry everything that failed" for one process definition key, as an asynchronous batch (large
   * volumes, survives restarts, visible in Cockpit). {@code dueDate == null} keeps the jobs' due dates.
   */
  public Batch retryFailedJobsAsync(String processDefinitionKey, int retries, Date dueDate) {
    requirePositive(retries);
    JobQuery failedJobs = managementService.createJobQuery()
        .processDefinitionKey(processDefinitionKey)
        .noRetriesLeft();
    var builder = managementService.setJobRetriesByJobsAsync(retries).jobQuery(failedJobs);
    if (dueDate != null) {
      builder.dueDate(dueDate);
    }
    Batch batch = builder.executeAsync();
    LOG.info("Batch {} created: retries={} for failed jobs of '{}' ({} jobs)", batch.getId(), retries,
        processDefinitionKey, batch.getTotalJobs());
    return batch;
  }

  /** Retries one external task (resolves its failedExternalTask incident). */
  public void retryExternalTask(String externalTaskId, int retries) {
    requirePositive(retries);
    externalTaskService.setRetries(externalTaskId, retries);
    LOG.info("External task {}: retries set to {}", externalTaskId, retries);
  }

  /** Retries all external tasks of a topic that ran out of retries, as an asynchronous batch. */
  public Batch retryFailedExternalTasksAsync(String topicName, int retries) {
    requirePositive(retries);
    ExternalTaskQuery failed = externalTaskService.createExternalTaskQuery().topicName(topicName).noRetriesLeft();
    Batch batch = externalTaskService.updateRetries().externalTaskQuery(failed).setAsync(retries);
    LOG.info("Batch {} created: retries={} for failed external tasks of topic '{}'", batch.getId(), retries, topicName);
    return batch;
  }

  /** Leaves a note on an incident (who looked at it, ticket number) - shown in Cockpit. */
  public void annotateIncident(String incidentId, String annotation) {
    runtimeService.setAnnotationForIncidentById(incidentId, annotation);
  }

  /** Open incidents of a process definition, oldest first - the read side of the legacy cleanup script. */
  public List<Incident> openIncidents(String processDefinitionKey) {
    return runtimeService.createIncidentQuery()
        .processDefinitionKeyIn(processDefinitionKey)
        .orderByIncidentTimestamp().asc()
        .list();
  }

  private static Date now() {
    return ClockUtil.getCurrentTime();
  }

  private static void requirePositive(int retries) {
    if (retries <= 0) {
      throw new IllegalArgumentException("retries must be > 0 (0 would create incidents), was " + retries);
    }
  }
}
