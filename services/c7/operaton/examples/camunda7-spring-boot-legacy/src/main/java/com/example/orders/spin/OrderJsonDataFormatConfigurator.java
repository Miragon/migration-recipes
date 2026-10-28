package com.example.orders.spin;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.camunda.spin.impl.json.jackson.format.JacksonJsonDataFormat;
import org.camunda.spin.spi.DataFormatConfigurator;

/**
 * Customises the ObjectMapper Spin uses for JSON process variables.
 *
 * <p>Loaded via Java ServiceLoader from
 * {@code META-INF/services/org.camunda.spin.spi.DataFormatConfigurator}, NOT via Spring.
 *
 * <p>MIGRATION HOTSPOT (silent): after the package rename the services file must be renamed
 * to {@code org.operaton.spin.spi.DataFormatConfigurator} AND its content must still point to
 * this class. If either is wrong, nothing fails - Spin just silently falls back to its
 * default ObjectMapper (Java time types are then serialised differently / fail).
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
