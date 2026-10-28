package com.example.orders;

import static org.assertj.core.api.Assertions.assertThat;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.assertThat;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.complete;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.execute;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.externalTaskService;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.formService;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.historyService;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.job;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.runtimeService;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.task;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.withVariables;

import com.example.orders.history.ExportedHistoryEvent;
import com.example.orders.history.InMemoryEventPublisher;
import com.example.orders.listener.TaskLifecycleLogger;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import org.camunda.bpm.engine.externaltask.LockedExternalTask;
import org.camunda.bpm.engine.runtime.ProcessInstance;
import org.camunda.spin.json.SpinJsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

class OrderFulfillmentProcessTest extends AbstractProcessEngineTest {

  private static final String PROCESS_KEY = "order-fulfillment";

  @Autowired
  InMemoryEventPublisher eventPublisher;

  @Autowired
  TaskLifecycleLogger taskLifecycleLogger;

  @Test
  void largeOrderIsApprovedAndShipped() throws Exception {
    ProcessInstance pi = runtimeService().startProcessInstanceByKey(PROCESS_KEY, "A-4711",
        withVariables("orderId", "A-4711", "customerType", "REGULAR", "amount", 2500L));

    // asyncBefore on the service task -> the instance waits for the job
    assertThat(pi).isStarted().isWaitingAt("Task_CheckInventory");
    execute(job());

    // delegate -> DMN -> Groovy/Spin script -> gateway -> user task
    assertThat(pi)
        .hasPassed("Task_CheckInventory", "Task_DetermineDiscount", "Task_BuildSummary")
        .isWaitingAt("Task_ApproveOrder");
    assertThat(pi).variables()
        .containsEntry("inStock", true)
        .containsEntry("discount", 5)
        .containsEntry("auditStarted", true)
        .containsKey("orderSummary");

    SpinJsonNode summary = (SpinJsonNode) runtimeService().getVariable(pi.getId(), "orderSummary");
    assertThat(summary.prop("orderId").stringValue()).isEqualTo("A-4711");
    assertThat(summary.prop("approvalRequired").boolValue()).isTrue();

    // MIGRATION HOTSPOT: the "camunda-forms:" form key prefix must still be resolvable
    assertThat(task())
        .hasCandidateGroup("order-ops")
        .hasFormKey("camunda-forms:deployment:approve-order.form");
    try (InputStream form = formService().getDeployedTaskForm(task().getId())) {
      assertThat(new String(form.readAllBytes(), StandardCharsets.UTF_8)).contains("\"id\": \"approve-order\"");
    }

    // Spring event bridge (camunda.bpm.eventing.task=true) saw the task being created
    assertThat(taskLifecycleLogger.createdTaskKeys()).contains(pi.getId() + ":Task_ApproveOrder");

    complete(task(), withVariables("approved", true));

    // external task worker
    assertThat(pi).isWaitingAt("Task_ShipOrder").externalTask().hasTopicName("ship-order");
    List<LockedExternalTask> locked = externalTaskService().fetchAndLock(10, "shipping-worker")
        .topic("ship-order", 30_000L)
        .processInstanceVariableEquals("orderId", "A-4711")
        .execute();
    assertThat(locked).hasSize(1);
    externalTaskService().complete(locked.get(0).getId(), "shipping-worker", Map.of("trackingNumber", "TRK-0001"));

    assertThat(pi).isEnded().hasPassed("Task_ShipOrder", "EndEvent_OrderShipped");
    assertThat(historyService().createHistoricVariableInstanceQuery()
        .processInstanceId(pi.getId()).variableName("trackingNumber").singleResult().getValue())
        .isEqualTo("TRK-0001");

    // custom history exporter received the events of this instance
    List<ExportedHistoryEvent> exported = eventPublisher.eventsFor(pi.getId());
    assertThat(exported).isNotEmpty();
    assertThat(exported).extracting(ExportedHistoryEvent::activityId)
        .contains("Task_CheckInventory", "Task_DetermineDiscount", "Task_ApproveOrder", "Task_ShipOrder");
    assertThat(exported).extracting(ExportedHistoryEvent::processDefinitionKey).containsOnly(PROCESS_KEY);

    // MIGRATION HOTSPOT (deliberate): downstream consumers see the engine's class names.
    // This assertion FAILS after the package rename (org.operaton...) - exactly like a Kafka
    // consumer/stream filter that routes on "eventClass" would. Adapt consumers + this test.
    assertThat(exported).allSatisfy(event ->
        assertThat(event.eventClass()).startsWith("org.camunda.bpm.engine."));
  }

  @Test
  void smallVipOrderSkipsApproval() {
    ProcessInstance pi = runtimeService().startProcessInstanceByKey(PROCESS_KEY, "B-0815",
        withVariables("orderId", "B-0815", "customerType", "VIP", "amount", 300L));

    assertThat(pi).isWaitingAt("Task_CheckInventory");
    execute(job());

    assertThat(pi).hasNotPassed("Task_ApproveOrder").isWaitingAt("Task_ShipOrder");
    assertThat(pi).variables().containsEntry("discount", 10);
  }

  @Test
  void reminderIsSentAfter24hWithoutCancellingApproval() {
    ProcessInstance pi = runtimeService().startProcessInstanceByKey(PROCESS_KEY, "C-0042",
        withVariables("orderId", "C-0042", "customerType", "REGULAR", "amount", 5000L));
    assertThat(pi).isWaitingAt("Task_CheckInventory");
    execute(job());
    assertThat(pi).isWaitingAt("Task_ApproveOrder");

    execute(job("BoundaryEvent_Reminder"));

    assertThat(pi).hasPassed("Task_SendReminder", "EndEvent_ReminderSent").isWaitingAt("Task_ApproveOrder");
    assertThat(pi).variables().containsEntry("reminderSent", true);

    complete(task(), withVariables("approved", false));
    assertThat(pi).isEnded().hasPassed("EndEvent_OrderRejected");
  }
}
