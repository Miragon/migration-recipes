package com.example.orders.listener;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import org.operaton.bpm.spring.boot.starter.event.TaskEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

/**
 * Spring event bridge listener (requires {@code operaton.bpm.eventing.task=true}).
 *
 * <p>MIGRATED: two things changed together - the event type
 * ({@code org.operaton.bpm.spring.boot.starter.event.TaskEvent}, recipe) and the property
 * ({@code camunda.bpm.eventing.task} -> {@code operaton.bpm.eventing.task}, recipe). With only the
 * Java part migrated, the listener would compile but silently never fire.
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
