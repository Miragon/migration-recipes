package com.example.orders;

import org.camunda.bpm.spring.boot.starter.annotation.EnableProcessApplication;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Order fulfillment process application (legacy Camunda 7.24 CE).
 *
 * <p>MIGRATION HOTSPOT: {@code @EnableProcessApplication} switches deployment from the
 * starter's auto-deployment to {@code META-INF/processes.xml}. Both the annotation package
 * ({@code org.camunda.bpm.spring.boot.starter.annotation}) and the XML namespace of
 * processes.xml change during the migration.
 */
@SpringBootApplication
@EnableProcessApplication("order-fulfillment-app")
public class OrderFulfillmentApplication {

  public static void main(String[] args) {
    SpringApplication.run(OrderFulfillmentApplication.class, args);
  }
}
