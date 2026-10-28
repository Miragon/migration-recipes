package com.example.orders.operations;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.execute;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.externalTaskService;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.historyService;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.job;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.managementService;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.runtimeService;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.withVariables;

import com.example.orders.AbstractProcessEngineTest;
import java.time.Instant;
import java.util.Date;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.operaton.bpm.engine.batch.Batch;
import org.operaton.bpm.engine.externaltask.ExternalTask;
import org.operaton.bpm.engine.externaltask.LockedExternalTask;
import org.operaton.bpm.engine.runtime.Incident;
import org.operaton.bpm.engine.runtime.Job;
import org.operaton.bpm.engine.runtime.ProcessInstance;
import org.springframework.beans.factory.annotation.Autowired;

/** Replaces ops/sql/retry-failed-jobs.sql and ops/sql/cleanup-incidents.sql (decision D10). */
class IncidentRecoveryServiceTest extends AbstractProcessEngineTest {

  @Autowired
  IncidentRecoveryService recovery;

  @Test
  void annotatesAndRetriesASingleFailedJob() {
    ProcessInstance pi = startFailingOrder("FAIL-R1");
    Job failed = exhaustRetries(pi);
    Incident incident = incidentOf(pi);

    recovery.annotateIncident(incident.getId(), "OPS-4711: inventory service restarted, retrying");
    assertThat(incidentOf(pi).getAnnotation()).isEqualTo("OPS-4711: inventory service restarted, retrying");
    assertThat(recovery.openIncidents("order-fulfillment")).extracting(Incident::getId).contains(incident.getId());

    recovery.retryJob(failed.getId(), 1);

    Job retried = jobOf(pi);
    assertThat(retried.getRetries()).isEqualTo(1);
    assertThat(retried.getDuedate()).isBeforeOrEqualTo(new Date());   // retry cycle had pushed it ~1 minute out
    assertThat(runtimeService().createIncidentQuery().processInstanceId(pi.getId()).count()).isZero();
    assertThat(historyService().createHistoricIncidentQuery().incidentId(incident.getId()).singleResult().isResolved())
        .as("resolved with history - unlike DELETE FROM ACT_RU_INCIDENT").isTrue();
  }

  @Test
  void retriesAllFailedJobsOfOneJobDefinition() {
    ProcessInstance first = startFailingOrder("FAIL-D1");
    ProcessInstance second = startFailingOrder("FAIL-D2");
    Job failed = exhaustRetries(first);
    exhaustRetries(second);

    recovery.retryJobsOfDefinition(failed.getJobDefinitionId(), 2);

    assertThat(jobOf(first).getRetries()).isEqualTo(2);
    assertThat(jobOf(second).getRetries()).isEqualTo(2);
    // by job definition the engine runs one bulk UPDATE (JobManager#updateFailedJobRetriesByJobDefinitionId):
    // the failedJob incidents stay open until each job runs successfully - unlike retryJob / the batch
    assertThat(runtimeService().createIncidentQuery().processInstanceId(first.getId()).count()).isEqualTo(1);
    assertThat(runtimeService().createIncidentQuery().processInstanceId(second.getId()).count()).isEqualTo(1);
  }

  @Test
  void retriesFailedJobsAsBatchWithDueDate() {
    ProcessInstance pi = startFailingOrder("FAIL-B1");
    exhaustRetries(pi);
    Date dueDate = Date.from(Instant.parse("2030-01-01T06:00:00Z"));

    Batch batch = recovery.retryFailedJobsAsync("order-fulfillment", 1, dueDate);
    executeBatch(batch);   // the job executor is off in tests; in production it runs the batch

    Job retried = jobOf(pi);
    assertThat(retried.getRetries()).isEqualTo(1);
    assertThat(retried.getDuedate()).isEqualTo(dueDate);
    assertThat(runtimeService().createIncidentQuery().processInstanceId(pi.getId()).count()).isZero();
  }

  @Test
  void retriesFailedExternalTasks() {
    ProcessInstance single = startOrderWaitingForShipment("X-1");
    ProcessInstance viaBatch = startOrderWaitingForShipment("X-2");
    failShipment(single);
    failShipment(viaBatch);
    assertThat(incidentOf(single).getIncidentType()).isEqualTo(Incident.EXTERNAL_TASK_HANDLER_TYPE);
    assertThat(incidentOf(viaBatch).getIncidentType()).isEqualTo(Incident.EXTERNAL_TASK_HANDLER_TYPE);

    recovery.retryExternalTask(externalTaskOf(single).getId(), 3);
    assertThat(externalTaskOf(single).getRetries()).isEqualTo(3);
    assertThat(runtimeService().createIncidentQuery().processInstanceId(single.getId()).count()).isZero();

    executeBatch(recovery.retryFailedExternalTasksAsync("ship-order", 2));
    assertThat(externalTaskOf(viaBatch).getRetries()).isEqualTo(2);
    assertThat(runtimeService().createIncidentQuery().processInstanceId(viaBatch.getId()).count()).isZero();
  }

  @Test
  void refusesZeroRetries() {
    assertThatThrownBy(() -> recovery.retryJob("any", 0)).isInstanceOf(IllegalArgumentException.class);
  }

  // ------------------------------------------------------------------------------------------------

  private static ProcessInstance startFailingOrder(String orderId) {
    return runtimeService().startProcessInstanceByKey("order-fulfillment", orderId,
        withVariables("orderId", orderId, "customerType", "REGULAR", "amount", 100L));
  }

  /** R3/PT1M -> three failing attempts -> retries 0 + failedJob incident. */
  private static Job exhaustRetries(ProcessInstance pi) {
    Job job = jobOf(pi);
    for (int attempt = 0; attempt < 3; attempt++) {
      String jobId = job.getId();
      assertThatThrownBy(() -> managementService().executeJob(jobId)).hasMessageContaining("Inventory service unavailable");
    }
    assertThat(jobOf(pi).getRetries()).isZero();
    return jobOf(pi);
  }

  private static ProcessInstance startOrderWaitingForShipment(String orderId) {
    ProcessInstance pi = runtimeService().startProcessInstanceByKey("order-fulfillment", orderId,
        withVariables("orderId", orderId, "customerType", "VIP", "amount", 50L));
    execute(job(pi));   // async inventory check -> DMN -> script -> no approval -> external task
    return pi;
  }

  private static void failShipment(ProcessInstance pi) {
    List<LockedExternalTask> locked = externalTaskService().fetchAndLock(1, "shipping-worker")
        .topic("ship-order", 30_000L)
        .businessKey(pi.getBusinessKey())
        .execute();
    assertThat(locked).hasSize(1);
    externalTaskService().handleFailure(locked.get(0).getId(), "shipping-worker", "carrier API down", 0, 0);
  }

  private static ExternalTask externalTaskOf(ProcessInstance pi) {
    return externalTaskService().createExternalTaskQuery().processInstanceId(pi.getId()).singleResult();
  }

  private static Job jobOf(ProcessInstance pi) {
    return managementService().createJobQuery().processInstanceId(pi.getId()).singleResult();
  }

  private static Incident incidentOf(ProcessInstance pi) {
    return runtimeService().createIncidentQuery().processInstanceId(pi.getId()).singleResult();
  }

  /** Seed job creates the batch jobs, batch jobs do the work; the monitor job only tracks completion. */
  private static void executeBatch(Batch batch) {
    for (Job seed : managementService().createJobQuery().jobDefinitionId(batch.getSeedJobDefinitionId()).list()) {
      managementService().executeJob(seed.getId());
    }
    for (Job batchJob : managementService().createJobQuery().jobDefinitionId(batch.getBatchJobDefinitionId()).list()) {
      managementService().executeJob(batchJob.getId());
    }
  }
}
