package com.example.orders.history;

import java.util.ArrayList;
import java.util.List;
import org.camunda.bpm.engine.impl.cfg.AbstractProcessEnginePlugin;
import org.camunda.bpm.engine.impl.cfg.ProcessEngineConfigurationImpl;
import org.camunda.bpm.engine.impl.history.handler.HistoryEventHandler;
import org.springframework.stereotype.Component;

/**
 * Process engine plugin that registers the {@link ExportingHistoryEventHandler} in addition
 * to the default database history handler. The Spring Boot starter picks up every
 * {@code ProcessEnginePlugin} bean automatically.
 *
 * <p>MIGRATION HOTSPOT: extends the internal {@code AbstractProcessEnginePlugin} and calls
 * {@code ProcessEngineConfigurationImpl} setters - typical for custom exporters/auditing.
 */
@Component
public class HistoryExportPlugin extends AbstractProcessEnginePlugin {

  private final ExportingHistoryEventHandler exportingHandler;

  public HistoryExportPlugin(ExportingHistoryEventHandler exportingHandler) {
    this.exportingHandler = exportingHandler;
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
