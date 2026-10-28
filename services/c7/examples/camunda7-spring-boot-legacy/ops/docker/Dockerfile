# Runtime image for the legacy app (build first: mvn -B package).
#
# MIGRATION HOTSPOTS: env var names (CAMUNDA_BPM_*), the health check URL path (/camunda/app/)
# and image/artifact names.
#
# Why the jar is extracted: with @EnableProcessApplication, a plain `java -jar` fat jar deploys
# its resources as "BOOT-INF/classes/approve-order.form". The form key
# "camunda-forms:deployment:approve-order.form" then no longer resolves. The extracted layout
# (Spring Boot's recommended container layout) keeps the plain names. Camunda 7.24 and
# Operaton behave the same here, so this is not a migration issue.

FROM eclipse-temurin:17-jre AS extract
WORKDIR /build
COPY target/camunda7-spring-boot-legacy-*.jar app.jar
RUN java -Djarmode=tools -jar app.jar extract --destination extracted

FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=extract /build/extracted/ ./

ENV CAMUNDA_BPM_WEBAPP_APPLICATION_PATH=/camunda \
    CAMUNDA_BPM_HISTORY_LEVEL=full

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=5 \
  CMD wget -qO- http://localhost:8080/camunda/app/welcome/default/ >/dev/null || exit 1

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
