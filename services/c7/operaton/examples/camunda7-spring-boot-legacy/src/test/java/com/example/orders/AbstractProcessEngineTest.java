package com.example.orders;

import org.camunda.bpm.engine.ProcessEngine;
import org.camunda.bpm.engine.test.assertions.bpmn.BpmnAwareTests;
import org.junit.jupiter.api.BeforeEach;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;

/**
 * Shared Spring Boot test setup: one application context (H2 in-memory, job executor
 * disabled via application-test.yaml) for all test classes.
 *
 * <p>MIGRATION HOTSPOT: camunda-bpm-assert ({@code org.camunda.bpm.engine.test.assertions.*})
 * becomes operaton-bpm-assert ({@code org.operaton.bpm.engine.test.assertions.*}).
 */
@SpringBootTest
@ActiveProfiles("test")
public abstract class AbstractProcessEngineTest {

  @Autowired
  protected ProcessEngine processEngine;

  @BeforeEach
  void initAssertions() {
    BpmnAwareTests.init(processEngine);
  }
}
