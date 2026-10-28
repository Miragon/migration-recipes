package com.example.orders.listener;

import org.camunda.bpm.engine.delegate.DelegateExecution;
import org.camunda.bpm.engine.delegate.ExecutionListener;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Process-level execution listener, referenced from BPMN via
 * {@code <camunda:executionListener class="com.example.orders.listener.OrderAuditListener" .../>}.
 *
 * <p>MIGRATION HOTSPOT: the engine instantiates this class reflectively (not a Spring bean),
 * so a wrong FQCN in the BPMN only fails at runtime. The {@code camunda:class} attribute
 * itself keeps working on Operaton; only the Java interface package changes.
 */
public class OrderAuditListener implements ExecutionListener {

  private static final Logger LOG = LoggerFactory.getLogger(OrderAuditListener.class);

  @Override
  public void notify(DelegateExecution execution) {
    LOG.info("AUDIT {} process {} for order {} (businessKey={})",
        execution.getEventName(),
        execution.getProcessInstanceId(),
        execution.getVariable("orderId"),
        execution.getProcessBusinessKey());
    if (EVENTNAME_START.equals(execution.getEventName())) {
      execution.setVariable("auditStarted", true);
    }
  }
}
