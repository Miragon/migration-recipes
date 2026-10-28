package com.example.orders;

import org.operaton.bpm.spring.boot.starter.annotation.EnableProcessApplication;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Order fulfillment process application (migrated from Camunda 7.24 CE to Operaton).
 *
 * <p>MIGRATED: {@code @EnableProcessApplication} now lives in
 * {@code org.operaton.bpm.spring.boot.starter.annotation}; the processes.xml namespace changed too.
 * Deployment still comes from {@code META-INF/processes.xml}, not from the starter's auto-deployment.
 */
@SpringBootApplication
@EnableProcessApplication("order-fulfillment-app")
public class OrderFulfillmentApplication {

  public static void main(String[] args) {
    SpringApplication.run(OrderFulfillmentApplication.class, args);
  }
}
