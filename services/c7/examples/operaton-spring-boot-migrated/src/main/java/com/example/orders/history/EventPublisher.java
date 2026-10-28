package com.example.orders.history;

/**
 * Outbound port for exported history events. In production this would be a Kafka/AMQP
 * producer; the sample uses {@link InMemoryEventPublisher}.
 */
public interface EventPublisher {

  void publish(ExportedHistoryEvent event);
}
