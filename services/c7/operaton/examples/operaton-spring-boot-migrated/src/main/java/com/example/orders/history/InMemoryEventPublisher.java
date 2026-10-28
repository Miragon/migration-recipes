package com.example.orders.history;

import tools.jackson.databind.ObjectMapper;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import tools.jackson.core.JacksonException;

/**
 * Stand-in for a Kafka producer: keeps every exported event in memory and logs it as JSON.
 *
 * <p>MIGRATED (Hop 2): Spring Boot 4 auto-configures a Jackson 3 {@code tools.jackson.databind.ObjectMapper};
 * the Hop 2 recipe moved this class to Jackson 3. Classes that touch Spin or the engine stay on
 * Jackson 2 (see {@code spin.OrderJsonDataFormatConfigurator}).
 */
@Component
public class InMemoryEventPublisher implements EventPublisher {

  private static final Logger LOG = LoggerFactory.getLogger(InMemoryEventPublisher.class);

  private final List<ExportedHistoryEvent> events = new CopyOnWriteArrayList<>();
  private final ObjectMapper objectMapper;

  public InMemoryEventPublisher(ObjectMapper objectMapper) {
    this.objectMapper = objectMapper;
  }

  @Override
  public void publish(ExportedHistoryEvent event) {
    events.add(event);
    if (LOG.isDebugEnabled()) {
      LOG.debug("export -> {}", toJson(event));
    }
  }

  public List<ExportedHistoryEvent> events() {
    return List.copyOf(events);
  }

  public List<ExportedHistoryEvent> eventsFor(String processInstanceId) {
    return events.stream().filter(e -> processInstanceId.equals(e.processInstanceId())).toList();
  }

  private String toJson(ExportedHistoryEvent event) {
    try {
      return objectMapper.writeValueAsString(event);
    } catch (JacksonException e) {
      return event.toString();
    }
  }
}
