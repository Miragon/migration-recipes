package com.example.orders.listener;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import org.camunda.bpm.spring.boot.starter.event.TaskEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

/**
 * Spring event bridge listener (requires {@code camunda.bpm.eventing.task=true}).
 *
 * <p>MIGRATION HOTSPOT: two things must change together:
 * <ul>
 *   <li>the event type {@code org.camunda.bpm.spring.boot.starter.event.TaskEvent}
 *       (package rename, handled by the recipe), and</li>
 *   <li>the property {@code camunda.bpm.eventing.task} in application.yaml. If the YAML key
 *       is not migrated, the listener still compiles but silently never fires
 *       (unless the target default happens to be "on").</li>
 * </ul>
 */
@Component
public class TaskLifecycleLogger {

  private static final Logger LOG = LoggerFactory.getLogger(TaskLifecycleLogger.class);

  private final List<String> createdTaskKeys = new CopyOnWriteArrayList<>();

  @EventListener(condition = "#taskEvent.eventName == 'create'")
  public void onTaskCreated(TaskEvent taskEvent) {
    LOG.info("Task '{}' ({}) created for process instance {}",
        taskEvent.getName(), taskEvent.getTaskDefinitionKey(), taskEvent.getProcessInstanceId());
    createdTaskKeys.add(taskEvent.getProcessInstanceId() + ":" + taskEvent.getTaskDefinitionKey());
  }

  /** Entries are formatted as {@code processInstanceId:taskDefinitionKey}. */
  public List<String> createdTaskKeys() {
    return List.copyOf(createdTaskKeys);
  }
}
