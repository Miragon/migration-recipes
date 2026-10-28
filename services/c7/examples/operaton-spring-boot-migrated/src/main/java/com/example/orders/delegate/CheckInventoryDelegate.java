package com.example.orders.delegate;

import org.operaton.bpm.engine.delegate.DelegateExecution;
import org.operaton.bpm.engine.delegate.JavaDelegate;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * Checks inventory for an order. Referenced from BPMN via
 * {@code camunda:delegateExpression="${checkInventoryDelegate}"}.
 *
 * <p>MIGRATED: implements {@code org.operaton.bpm.engine.delegate.JavaDelegate} (package rename by
 * the recipe). The BPMN attribute stays in the {@code camunda:} namespace, which Operaton reads.
 */
@Component("checkInventoryDelegate")
public class CheckInventoryDelegate implements JavaDelegate {

  /** Orders whose id starts with this prefix simulate an unavailable inventory system. */
  public static final String FAILING_ORDER_PREFIX = "FAIL-";

  private static final Logger LOG = LoggerFactory.getLogger(CheckInventoryDelegate.class);

  @Override
  public void execute(DelegateExecution execution) {
    String orderId = (String) execution.getVariable("orderId");
    if (orderId != null && orderId.startsWith(FAILING_ORDER_PREFIX)) {
      // Thrown from an asyncBefore job -> retries (R3/PT1M) -> incident -> custom IncidentHandler
      throw new IllegalStateException("Inventory service unavailable for order " + orderId);
    }
    LOG.info("Inventory checked for order {} (processInstanceId={})", orderId, execution.getProcessInstanceId());
    execution.setVariable("inStock", true);
  }
}
