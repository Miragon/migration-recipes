package com.example.orders.history;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.historyService;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.runtimeService;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.withVariables;

import com.example.orders.AbstractProcessEngineTest;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;
import org.operaton.bpm.engine.impl.history.event.HistoricProcessInstanceEventEntity;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * The engine joins a surrounding Spring transaction, so the test can control commit and rollback.
 * The handler sees the history events in both cases; only committed ones may reach the publisher, and
 * each of them exactly once (the handler is registered by {@link HistoryExportPlugin} only).
 */
class ExportingHistoryEventHandlerTest extends AbstractProcessEngineTest {

  @Autowired
  PlatformTransactionManager transactionManager;

  @Autowired
  InMemoryEventPublisher eventPublisher;

  @Test
  void rolledBackTransactionPublishesNoEvents() {
    AtomicReference<String> processInstanceId = new AtomicReference<>();

    new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
      processInstanceId.set(runtimeService().startProcessInstanceByKey("order-fulfillment", "TX-ROLLBACK",
          withVariables("orderId", "TX-ROLLBACK", "customerType", "REGULAR", "amount", 10L)).getId());
      status.setRollbackOnly();   // e.g. a later business step in the same transaction fails
    });

    assertThat(historyService().createHistoricProcessInstanceQuery()
        .processInstanceId(processInstanceId.get()).count()).as("instance was rolled back").isZero();
    // the Camunda-era handler published these events immediately ("ghost events")
    assertThat(eventPublisher.eventsFor(processInstanceId.get())).isEmpty();
  }

  @Test
  void committedTransactionPublishesAfterTheCommit() {
    AtomicReference<String> processInstanceId = new AtomicReference<>();

    new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
      processInstanceId.set(runtimeService().startProcessInstanceByKey("order-fulfillment", "TX-COMMIT",
          withVariables("orderId", "TX-COMMIT", "customerType", "REGULAR", "amount", 10L)).getId());
      assertThat(eventPublisher.eventsFor(processInstanceId.get())).as("nothing before the commit").isEmpty();
    });

    assertThat(eventPublisher.eventsFor(processInstanceId.get()))
        .isNotEmpty()
        .extracting(ExportedHistoryEvent::eventClass)
        .contains(HistoricProcessInstanceEventEntity.class.getName());
  }

  @Test
  void everyEventIsExportedExactlyOnce() {
    String processInstanceId = runtimeService().startProcessInstanceByKey("order-fulfillment", "TX-ONCE",
        withVariables("orderId", "TX-ONCE", "customerType", "REGULAR", "amount", 10L)).getId();

    // the Camunda-era registration (@Component handler + plugin) registered the handler twice: ["start", "start"]
    assertThat(eventPublisher.eventsFor(processInstanceId))
        .filteredOn(event -> HistoricProcessInstanceEventEntity.class.getName().equals(event.eventClass()))
        .extracting(ExportedHistoryEvent::eventType)
        .containsExactly("start");
    assertThat(eventPublisher.eventsFor(processInstanceId))
        .filteredOn(event -> "StartEvent_OrderReceived".equals(event.activityId()))
        .extracting(ExportedHistoryEvent::eventType)
        .containsExactly("start", "end");
  }

  @Test
  void publisherFailureDoesNotReachTheCaller() {
    ExportingHistoryEventHandler handler = new ExportingHistoryEventHandler(event -> {
      throw new IllegalStateException("broker down");
    });
    HistoricProcessInstanceEventEntity event = new HistoricProcessInstanceEventEntity();
    event.setEventType("start");
    event.setProcessInstanceId("pi-1");

    // outside an engine command the handler publishes directly - and still swallows the failure
    assertThatCode(() -> handler.handleEvent(event)).doesNotThrowAnyException();
  }
}
