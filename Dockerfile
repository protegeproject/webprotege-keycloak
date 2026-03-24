FROM keycloak/keycloak:26.1
COPY ./webprotege /opt/keycloak/themes/webprotege
COPY ./spi/target/webprotege-credential-check-authenticator-*.jar /opt/keycloak/providers/
COPY ./webprotege.json /opt/keycloak/import/webprotege.json
RUN /opt/keycloak/bin/kc.sh build
