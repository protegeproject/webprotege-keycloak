FROM keycloak/keycloak:26.1
COPY ./webprotege /opt/keycloak/themes/webprotege
COPY ./spi/target/webprotege-credential-check-authenticator-1.0.0.jar /opt/keycloak/providers/
RUN /opt/keycloak/bin/kc.sh build
