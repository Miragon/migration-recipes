# Runtime image for the migrated app (build first: mvn -B package).
#
# MIGRATED: CAMUNDA_BPM_* -> OPERATON_BPM_* (starterpack.operaton.InfraEnvVars) and the jar name.
# KEPT (decision D6): the webapps stay at /camunda for the cut-over release, so the health check URL
# below is unchanged. Moving to /operaton later: change OPERATON_BPM_WEBAPP_APPLICATION_PATH, this
# health check and the ingress, and enable orders.migration.legacy-webapp-redirect for old bookmarks.
#
# Why the jar is extracted: with @EnableProcessApplication, a plain `java -jar` fat jar deploys
# its resources as "BOOT-INF/classes/approve-order.form". The form key
# "operaton-forms:deployment:approve-order.form" then no longer resolves. The extracted layout
# (Spring Boot's recommended container layout) keeps the plain names. Camunda 7.24 and
# Operaton behave the same here, so this is not a migration issue.

FROM eclipse-temurin:17-jre AS extract
WORKDIR /build
COPY target/operaton-spring-boot-migrated-*.jar app.jar
RUN java -Djarmode=tools -jar app.jar extract --destination extracted

FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=extract /build/extracted/ ./

ENV OPERATON_BPM_WEBAPP_APPLICATION_PATH=/camunda \
    OPERATON_BPM_HISTORY_LEVEL=full

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=5 \
  CMD wget -qO- http://localhost:8080/camunda/app/welcome/default/ >/dev/null || exit 1

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
