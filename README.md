# webprotege-keycloak

Keycloak configuration for WebProtege. This repository contains:

- **Realm configuration** (`webprotege.json`) for the `webprotege` realm
- **Custom login theme** (`webprotege/`) matching WebProtege branding
- **Migrated user authenticator plugin** (`spi/`) that detects users migrated from legacy WebProtege who don't have a password yet and sends them a password reset email on their first login

## Prerequisites

- Java 17+
- Maven 3.8+
- Docker

## Building the Plugin

The authenticator plugin must be built before deploying Keycloak:

```bash
cd spi
mvn clean package
```

This produces `spi/target/webprotege-credential-check-authenticator-1.0.0.jar`.

## Docker Build

The `Dockerfile` packages the theme, plugin, and realm configuration into a custom Keycloak image:

```dockerfile
FROM keycloak/keycloak:26.1
COPY ./webprotege /opt/keycloak/themes/webprotege
COPY ./spi/target/webprotege-credential-check-authenticator-1.0.0.jar /opt/keycloak/providers/
COPY ./webprotege.json /opt/keycloak/import/webprotege.json
RUN /opt/keycloak/bin/kc.sh build
```

To build locally:

```bash
cd spi && mvn clean package && cd ..
docker build -t protegeproject/webprotege-keycloak:1.0.0 .
```

## Deployment

For full deployment instructions, see the [webprotege-deploy README](../webprotege-deploy/README.md).

## SMTP Configuration

The realm requires an SMTP server for the migrated user password reset flow. In development, Mailpit is used (configured in the `webprotege-deploy` Docker Compose). The SMTP settings are defined in the realm JSON under `smtpServer`.
