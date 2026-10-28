package com.example.orders.config;

import org.operaton.bpm.spring.boot.starter.property.OperatonBpmProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

/**
 * Builds deep links into Cockpit/Tasklist (e.g. for incident notifications or e-mails).
 *
 * <p>MIGRATED (Hop 1): {@code CamundaBpmProperties} became {@code OperatonBpmProperties}, bound to
 * {@code operaton.bpm.*}. Operaton's default webapp path is {@code /operaton}; this app keeps
 * {@code /camunda} explicitly ({@code operaton.bpm.webapp.application-path}, decision D6), so the
 * links in mails, ingress rules and bookmarks stay valid. When the path moves later, these links
 * follow automatically and {@code migration.LegacyWebappPathRedirectFilter} redirects old bookmarks.
 */
@Component
public class WebappLinks {

  private static final Logger LOG = LoggerFactory.getLogger(WebappLinks.class);

  private final OperatonBpmProperties operatonBpmProperties;
  private final String serverBaseUrl;

  public WebappLinks(OperatonBpmProperties operatonBpmProperties,
                     @Value("${orders.server-base-url:http://localhost:8080}") String serverBaseUrl) {
    this.operatonBpmProperties = operatonBpmProperties;
    this.serverBaseUrl = serverBaseUrl;
  }

  public String applicationPath() {
    return operatonBpmProperties.getWebapp().getApplicationPath();
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
