package com.example.orders;

import static org.assertj.core.api.Assertions.assertThat;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.repositoryService;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.runtimeService;
import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.withVariables;

import com.example.orders.config.WebappLinks;
import com.example.orders.history.ExportingHistoryEventHandler;
import com.example.orders.history.HistoryExportPlugin;
import com.example.orders.incident.NotifyingFailedJobIncidentHandler;
import com.example.orders.migration.AdminGroupMigrationPlugin;
import java.time.LocalDate;
import org.operaton.bpm.engine.impl.cfg.ProcessEngineConfigurationImpl;
import org.operaton.bpm.engine.repository.ProcessDefinition;
import org.operaton.bpm.engine.runtime.ProcessInstance;
import org.operaton.bpm.engine.variable.Variables;
import org.operaton.bpm.engine.variable.value.ObjectValue;
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
  HistoryExportPlugin historyExportPlugin;

  private ProcessEngineConfigurationImpl configuration() {
    return (ProcessEngineConfigurationImpl) processEngine.getProcessEngineConfiguration();
  }

  @Test
  void yamlConfigurationIsApplied() {
    // Decision D6: /camunda is kept explicitly (operaton.bpm.webapp.application-path); Operaton's default is /operaton
    assertThat(webappLinks.applicationPath()).isEqualTo("/camunda");
    assertThat(webappLinks.tasklistUrl()).isEqualTo("http://localhost:8080/camunda/app/tasklist/default/");

    assertThat(configuration().getHistoryLevel().getName()).isEqualTo("full");
    assertThat(configuration().isEnforceHistoryTimeToLive()).isTrue();
    assertThat(configuration().getHistoryTimeToLive()).isEqualTo("P180D");
    assertThat(configuration().getDefaultSerializationFormat()).isEqualTo("application/json");
    assertThat(processEngine.getFilterService().createFilterQuery().filterName("All tasks").count()).isEqualTo(1);
  }

  @Autowired
  AdminGroupMigrationPlugin adminGroupMigrationPlugin;

  @Test
  void pluginsAreRegistered() {
    // MIGRATED: registered exactly once - by the plugin; the handler is no longer a Spring bean that the
    // starter would register a second time
    assertThat(configuration().getCustomHistoryEventHandlers())
        .filteredOn(ExportingHistoryEventHandler.class::isInstance)
        .containsExactly(historyExportPlugin.exportingHandler());
    assertThat(configuration().isEnableDefaultDbHistoryEventHandler()).isTrue();
    assertThat(configuration().getIncidentHandler("failedJob")).isInstanceOf(NotifyingFailedJobIncidentHandler.class);
    // migration helper (decision D5) is active; the fresh test database has no camunda-admin data
    assertThat(adminGroupMigrationPlugin.isEnabled()).isTrue();
    assertThat(adminGroupMigrationPlugin.migrate(processEngine).nothingToDo()).isTrue();
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
    // Guards a SILENT migration hotspot: only works if META-INF/services/<spi>.DataFormatConfigurator
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
