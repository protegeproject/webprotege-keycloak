# webprotege-keycloak

Keycloak configuration for WebProtege. This repository contains:

- **Realm configuration** (`webprotege.json`) for the `webprotege` realm
- **Custom login theme** (`webprotege/`) matching WebProtege branding
- **Migrated user authenticator plugin** (`spi/`) that detects users migrated from legacy WebProtege who don't have a password yet and sends them a password reset email on their first login

## Prerequisites

- Java 17+
- Maven 3.8+

## Building the plugin

The authenticator plugin must be built before deploying Keycloak:

```bash
cd spi
mvn clean package
```

This produces `spi/target/webprotege-credential-check-authenticator-1.0.0.jar`.

## Docker build

The `Dockerfile` packages the theme and plugin into a custom Keycloak image:

```dockerfile
FROM keycloak/keycloak:26.1
COPY ./webprotege /opt/keycloak/themes/webprotege
COPY ./spi/target/webprotege-credential-check-authenticator-1.0.0.jar /opt/keycloak/providers/
RUN /opt/keycloak/bin/kc.sh build
```

## Deploying with webprotege-deploy

1. Build the plugin first:
   ```bash
   cd spi && mvn clean package && cd ..
   ```

2. From the `../webprotege-deploy` directory, build and start Keycloak:
   ```bash
   docker compose up --build keycloak
   ```

   The Docker Compose service references this repo's `Dockerfile` and will copy the built JAR into the image.

3. If this is a fresh deployment, import the realm configuration:
   ```bash
   docker compose exec keycloak /opt/keycloak/bin/kc.sh import --file /tmp/webprotege.json
   ```

## SMTP configuration

The realm requires an SMTP server for the migrated user password reset flow. In development, Mailpit is used (configured in the `webprotege-deploy` Docker Compose). The SMTP settings are defined in the realm JSON under `smtpServer`.
