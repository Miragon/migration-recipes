package com.example.orders.listener;

import org.operaton.bpm.engine.delegate.DelegateExecution;
import org.operaton.bpm.engine.delegate.ExecutionListener;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Process-level execution listener, referenced from BPMN via
 * {@code <camunda:executionListener class="com.example.orders.listener.OrderAuditListener" .../>}.
 *
 * <p>MIGRATED: the engine instantiates this class reflectively (not a Spring bean). The
 * {@code camunda:class} attribute keeps working on Operaton; only the interface package changed
 * ({@code org.operaton.bpm.engine.delegate.ExecutionListener}).
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
