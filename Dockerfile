FROM alpine:3 AS tools
ARG TARGETARCH
RUN wget -O /usr/local/bin/jq \
      "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${TARGETARCH}" \
    && chmod +x /usr/local/bin/jq

FROM maven:3.9-eclipse-temurin-17 AS spi-builder
WORKDIR /build
COPY spi/pom.xml .
RUN mvn dependency:go-offline -B
COPY spi/src ./src
RUN mvn package -B -DskipTests

FROM keycloak/keycloak:26.1
COPY --from=tools /usr/local/bin/jq /usr/bin/jq
COPY ./webprotege /opt/keycloak/themes/webprotege
COPY --from=spi-builder /build/target/webprotege-credential-check-authenticator-*.jar /opt/keycloak/providers/
COPY ./webprotege.json /opt/keycloak/import/webprotege.json
COPY --chmod=755 ./entrypoint.sh /opt/keycloak/bin/entrypoint.sh

# Runtime defaults so `kc.sh start` (production mode) works out of the box.
# The image is intended to sit behind a reverse proxy that terminates TLS,
# so plain HTTP is accepted inside the container.  hostname-strict is
# disabled because the public hostname varies by deployment; the entrypoint
# patches the realm's frontend URL to match SERVER_HOST at runtime.  Both
# are runtime options — override at `docker run` time if needed.
ENV KC_HTTP_ENABLED=true \
    KC_HOSTNAME_STRICT=false

RUN /opt/keycloak/bin/kc.sh build

ENTRYPOINT ["/opt/keycloak/bin/entrypoint.sh"]
