package com.example.orders.spin;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.operaton.spin.impl.json.jackson.format.JacksonJsonDataFormat;
import org.operaton.spin.spi.DataFormatConfigurator;

/**
 * Customises the ObjectMapper Spin uses for JSON process variables.
 *
 * <p>Loaded via Java ServiceLoader from
 * {@code META-INF/services/org.operaton.spin.spi.DataFormatConfigurator}, NOT via Spring.
 *
 * <p>MIGRATED (silent if wrong): the services file was renamed from
 * {@code org.camunda.spin.spi.DataFormatConfigurator} (official recipe); its content names this
 * class. A wrong file name or content does not fail - Spin silently falls back to its default
 * ObjectMapper. {@code ApplicationConfigurationTest#spinUsesCustomDataFormatConfigurator} guards it.
 *
 * <p>Operaton 2.x (Hop 2): Spin still uses Jackson 2 ({@code com.fasterxml.jackson}). Keep this
 * class on Jackson 2 even though Spring Boot 4 auto-configures Jackson 3 for the rest of the app -
 * the starter-pack Hop 2 recipe excludes classes that use Operaton types from the Jackson 3 rewrite.
 */
public class OrderJsonDataFormatConfigurator implements DataFormatConfigurator<JacksonJsonDataFormat> {

  @Override
  public Class<JacksonJsonDataFormat> getDataFormatClass() {
    return JacksonJsonDataFormat.class;
  }

  @Override
  public void configure(JacksonJsonDataFormat dataFormat) {
    ObjectMapper objectMapper = dataFormat.getObjectMapper();
    objectMapper.registerModule(new JavaTimeModule());
    objectMapper.disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
    objectMapper.disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);
  }
}
