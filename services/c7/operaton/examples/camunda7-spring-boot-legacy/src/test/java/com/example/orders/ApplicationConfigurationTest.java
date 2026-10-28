package com.example.orders;

import static org.assertj.core.api.Assertions.assertThat;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.repositoryService;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.runtimeService;
import static org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests.withVariables;

import com.example.orders.config.WebappLinks;
import com.example.orders.history.ExportingHistoryEventHandler;
import com.example.orders.incident.NotifyingFailedJobIncidentHandler;
import java.time.LocalDate;
import org.camunda.bpm.engine.impl.cfg.ProcessEngineConfigurationImpl;
import org.camunda.bpm.engine.repository.ProcessDefinition;
import org.camunda.bpm.engine.runtime.ProcessInstance;
import org.camunda.bpm.engine.variable.Variables;
import org.camunda.bpm.engine.variable.value.ObjectValue;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

/**
 * Guards that the YAML configuration, plugins and ServiceLoader files are really applied.
 * These are the things that break SILENTLY in a migration (unbound properties, renamed
 * services files), so they deserve explicit tests.
 */
class ApplicationConfigurationTest extends AbstractProcessEngineTest {

  record DeliveryWindow(String orderId, LocalDate earliest) {
  }

  @Autowired
  WebappLinks webappLinks;

  @Autowired
  ExportingHistoryEventHandler exportingHistoryEventHandler;

  private ProcessEngineConfigurationImpl configuration() {
    return (ProcessEngineConfigurationImpl) processEngine.getProcessEngineConfiguration();
  }

  @Test
  void yamlConfigurationIsApplied() {
    // MIGRATION HOTSPOT: Operaton's default would be /operaton
    assertThat(webappLinks.applicationPath()).isEqualTo("/camunda");
    assertThat(webappLinks.tasklistUrl()).isEqualTo("http://localhost:8080/camunda/app/tasklist/default/");

    assertThat(configuration().getHistoryLevel().getName()).isEqualTo("full");
    assertThat(configuration().isEnforceHistoryTimeToLive()).isTrue();
    assertThat(configuration().getHistoryTimeToLive()).isEqualTo("P180D");
    assertThat(configuration().getDefaultSerializationFormat()).isEqualTo("application/json");
    assertThat(processEngine.getFilterService().createFilterQuery().filterName("All tasks").count()).isEqualTo(1);
  }

  @Test
  void pluginsAreRegistered() {
    assertThat(configuration().getCustomHistoryEventHandlers()).contains(exportingHistoryEventHandler);
    assertThat(configuration().isEnableDefaultDbHistoryEventHandler()).isTrue();
    assertThat(configuration().getIncidentHandler("failedJob")).isInstanceOf(NotifyingFailedJobIncidentHandler.class);
  }

  @Test
  void processApplicationDeployedBpmnDmnAndForm() {
    ProcessDefinition definition = repositoryService().createProcessDefinitionQuery()
        .processDefinitionKey("order-fulfillment").latestVersion().singleResult();
    assertThat(repositoryService().getDeploymentResourceNames(definition.getDeploymentId()))
        .contains("order-fulfillment.bpmn", "order-discount.dmn", "approve-order.form");
  }

  @Test
  void spinUsesCustomDataFormatConfigurator() {
    // MIGRATION HOTSPOT (silent): only works if META-INF/services/<spi>.DataFormatConfigurator
    // has the right file name AND content. Without JavaTimeModule Jackson cannot serialise
    // LocalDate and setVariable fails.
    ProcessInstance pi = runtimeService().startProcessInstanceByKey("order-fulfillment", "D-1",
        withVariables("orderId", "D-1", "customerType", "REGULAR", "amount", 10L));

    runtimeService().setVariable(pi.getId(), "deliveryWindow",
        Variables.objectValue(new DeliveryWindow("D-1", LocalDate.of(2026, 10, 6)))
            .serializationDataFormat(Variables.SerializationDataFormats.JSON)
            .create());

    ObjectValue value = runtimeService().getVariableTyped(pi.getId(), "deliveryWindow", false);
    assertThat(value.getSerializationDataFormat()).isEqualTo("application/json");
    assertThat(value.getValueSerialized()).contains("\"earliest\":\"2026-10-06\"");
  }
}
