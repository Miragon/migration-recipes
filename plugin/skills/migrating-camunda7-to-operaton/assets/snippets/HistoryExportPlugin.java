package com.example.orders.history;

import java.util.ArrayList;
import java.util.List;
import org.operaton.bpm.engine.impl.cfg.AbstractProcessEnginePlugin;
import org.operaton.bpm.engine.impl.cfg.ProcessEngineConfigurationImpl;
import org.operaton.bpm.engine.impl.history.handler.HistoryEventHandler;
import org.operaton.bpm.spring.boot.starter.configuration.Ordering;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

/**
 * Process engine plugin that creates the {@link ExportingHistoryEventHandler} and registers it in
 * addition to the default database history handler. The Spring Boot starter picks up every
 * {@code ProcessEnginePlugin} bean automatically.
 *
 * <p>MIGRATED - registered exactly ONCE. The handler is deliberately not a Spring bean: the starter
 * ({@code DefaultHistoryConfiguration}) adds a single {@code HistoryEventHandler} bean to the custom
 * history event handlers by itself. The Camunda-era version made the handler a {@code @Component} AND
 * added it here, so every history event was exported twice (Camunda 7 has the same starter logic; see the
 * {@code MIGRATION HOTSPOT} in the legacy app). Construct the handler here, or expose it as a bean and drop
 * the plugin - never both. {@code ExportingHistoryEventHandlerTest} asserts one export per event.
 *
 * <p>{@code @Order(Ordering.DEFAULT_ORDER + 1)}: runs after the starter's own configurations (order 0),
 * so handlers the starter registered are kept and this one is appended deterministically.
 *
 * <p>Extends the internal {@code org.operaton.bpm.engine.impl.cfg.AbstractProcessEnginePlugin}
 * (package rename only; the plugin SPI is identical in Operaton 1.1.5 and 2.1.5).
 */
@Component
@Order(Ordering.DEFAULT_ORDER + 1)
public class HistoryExportPlugin extends AbstractProcessEnginePlugin {

  private final ExportingHistoryEventHandler exportingHandler;

  public HistoryExportPlugin(EventPublisher publisher) {
    this.exportingHandler = new ExportingHistoryEventHandler(publisher);
  }

  /** The handler this plugin registers (it is not a Spring bean) - for tests and diagnostics. */
  public ExportingHistoryEventHandler exportingHandler() {
    return exportingHandler;
  }

  @Override
  public void preInit(ProcessEngineConfigurationImpl configuration) {
    List<HistoryEventHandler> handlers = new ArrayList<>();
    if (configuration.getCustomHistoryEventHandlers() != null) {
      handlers.addAll(configuration.getCustomHistoryEventHandlers());
    }
    handlers.add(exportingHandler);
    configuration.setCustomHistoryEventHandlers(handlers);
    // keep writing ACT_HI_* tables - the exporter is additive
    configuration.setEnableDefaultDbHistoryEventHandler(true);
  }
}
