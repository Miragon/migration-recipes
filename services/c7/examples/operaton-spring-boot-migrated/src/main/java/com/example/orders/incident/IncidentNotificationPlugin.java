package com.example.orders.incident;

import java.util.ArrayList;
import java.util.List;
import org.operaton.bpm.engine.impl.cfg.AbstractProcessEnginePlugin;
import org.operaton.bpm.engine.impl.cfg.ProcessEngineConfigurationImpl;
import org.operaton.bpm.engine.impl.incident.IncidentHandler;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Registers {@link NotifyingFailedJobIncidentHandler} via a process engine plugin exposed as
 * Spring {@code @Bean} (the starter collects all ProcessEnginePlugin beans).
 */
@Configuration(proxyBeanMethods = false)
public class IncidentNotificationPlugin {

  @Bean
  public NotifyingFailedJobIncidentHandler notifyingFailedJobIncidentHandler() {
    return new NotifyingFailedJobIncidentHandler();
  }

  @Bean
  public AbstractProcessEnginePlugin incidentHandlerPlugin(NotifyingFailedJobIncidentHandler handler) {
    return new AbstractProcessEnginePlugin() {
      @Override
      public void preInit(ProcessEngineConfigurationImpl configuration) {
        List<IncidentHandler> handlers = new ArrayList<>();
        if (configuration.getCustomIncidentHandlers() != null) {
          handlers.addAll(configuration.getCustomIncidentHandlers());
        }
        handlers.add(handler);
        configuration.setCustomIncidentHandlers(handlers);
      }
    };
  }
}
