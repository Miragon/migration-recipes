package com.example.orders;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.assertThat;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.managementService;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.runtimeService;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.withVariables;

import com.example.orders.history.ExportedHistoryEvent;
import com.example.orders.history.InMemoryEventPublisher;
import com.example.orders.incident.NotifyingFailedJobIncidentHandler;
import org.operaton.bpm.engine.runtime.Incident;
import org.operaton.bpm.engine.runtime.Job;
import org.operaton.bpm.engine.runtime.ProcessInstance;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

class FailedJobIncidentTest extends AbstractProcessEngineTest {

  @Autowired
  NotifyingFailedJobIncidentHandler incidentHandler;

  @Autowired
  InMemoryEventPublisher eventPublisher;

  @Test
  void failingInventoryCheckRetriesThreeTimesThenRaisesIncident() {
    ProcessInstance pi = runtimeService().startProcessInstanceByKey("order-fulfillment", "FAIL-1",
        withVariables("orderId", "FAIL-1", "customerType", "REGULAR", "amount", 100L));
    Job job = managementService().createJobQuery().processInstanceId(pi.getId()).singleResult();

    // R3/PT1M -> three attempts; executeJob ignores the due date so we do not need to wait
    for (int attempt = 1; attempt <= 3; attempt++) {
      assertThatThrownBy(() -> managementService().executeJob(job.getId()))
          .hasMessageContaining("Inventory service unavailable");
      assertThat(refresh(job)).hasRetries(3 - attempt);
    }

    Incident incident = runtimeService().createIncidentQuery().processInstanceId(pi.getId()).singleResult();
    assertThat(incident).isNotNull();
    assertThat(incident.getIncidentType()).isEqualTo(Incident.FAILED_JOB_HANDLER_TYPE);
    assertThat(incident.getActivityId()).isEqualTo("Task_CheckInventory");

    // our custom IncidentHandler (registered via plugin) was invoked
    assertThat(incidentHandler.notifiedIncidentIds()).contains(incident.getId());

    // ... and the history exporter saw the incident too
    assertThat(eventPublisher.eventsFor(pi.getId()))
        .extracting(ExportedHistoryEvent::eventClass)
        .anyMatch(eventClass -> eventClass.endsWith("HistoricIncidentEventEntity"));
  }

  private Job refresh(Job job) {
    return managementService().createJobQuery().jobId(job.getId()).singleResult();
  }
}
