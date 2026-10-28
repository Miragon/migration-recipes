package com.example.orders.config;

import org.camunda.bpm.spring.boot.starter.property.CamundaBpmProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

/**
 * Builds deep links into Cockpit/Tasklist (e.g. for incident notifications or e-mails).
 *
 * <p>MIGRATION HOTSPOT: injects the starter's {@code CamundaBpmProperties} (bound to
 * {@code camunda.bpm.*}). After the migration the class is renamed and bound to a different
 * prefix; the default webapp path changes from {@code /camunda} to {@code /operaton}, so
 * every hard-coded or derived link (mails, ingress, bookmarks, monitoring) changes too.
 */
@Component
public class WebappLinks {

  private static final Logger LOG = LoggerFactory.getLogger(WebappLinks.class);

  private final CamundaBpmProperties camundaBpmProperties;
  private final String serverBaseUrl;

  public WebappLinks(CamundaBpmProperties camundaBpmProperties,
                     @Value("${orders.server-base-url:http://localhost:8080}") String serverBaseUrl) {
    this.camundaBpmProperties = camundaBpmProperties;
    this.serverBaseUrl = serverBaseUrl;
  }

  public String applicationPath() {
    return camundaBpmProperties.getWebapp().getApplicationPath();
  }

  public String cockpitProcessInstanceUrl(String processInstanceId) {
    return serverBaseUrl + applicationPath() + "/app/cockpit/default/#/process-instance/" + processInstanceId;
  }

  public String tasklistUrl() {
    return serverBaseUrl + applicationPath() + "/app/tasklist/default/";
  }

  @EventListener(ApplicationReadyEvent.class)
  public void logLinks() {
    LOG.info("Webapps available at {}{}/app/ (tasklist: {})", serverBaseUrl, applicationPath(), tasklistUrl());
  }
}
