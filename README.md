# webprotege-keycloak

Keycloak configuration for WebProtege. This repository contains:

- **Realm configuration** (`webprotege.json`) for the `webprotege` realm
- **Custom login theme** (`webprotege/`) matching WebProtege branding
- **Migrated user authenticator plugin** (`spi/`) that detects users migrated from legacy WebProtege who don't have a password yet and sends them a password reset email on their first login

## Prerequisites

- Docker

## Docker Build

The `Dockerfile` uses a multi-stage build to compile the authenticator plugin,
download tools, and package the theme, realm configuration, and startup
entrypoint into a custom Keycloak image.  No local Java or Maven installation
is required.

To build locally:

```bash
docker build -t protegeproject/webprotege-keycloak:1.2.0 .
```

## Startup Entrypoint

The image includes a custom entrypoint script (`entrypoint.sh`) that wraps the
standard Keycloak startup.  It starts Keycloak normally, waits for the realm
import to complete, then applies two configuration patches that cannot be
achieved through the realm import alone.

### 1. Protocol Mapper Fix

Keycloak's realm import mechanism has a known limitation: it silently drops the
`config` dictionary for certain protocol mapper types.  The realm JSON defines a
`username` mapper in the `profile` client scope that maps the custom user
attribute `webprotege_username` to the `preferred_username` JWT claim.  After
import, Keycloak reverts this mapper to its built-in default, which maps the
Keycloak username field instead.

This matters because WebProtege uses email addresses as Keycloak usernames, but
internal application lookups rely on the original MongoDB user ID stored in the
`webprotege_username` attribute.  Without the fix, the backend receives email
addresses where it expects user IDs, breaking user resolution.

The entrypoint detects this condition on each startup and, if the mapper is in
the wrong state, deletes it and recreates it with the correct configuration.
On subsequent boots where the mapper is already correct, the fix is skipped.

### 2. Hostname-Based Client URI Patching

The realm JSON ships with a default hostname baked into the `webprotege`
client's redirect URIs, web origins, and base URL.  Self-hosted deployments use
different hostnames.  When the `SERVER_HOST` environment variable is set, the
entrypoint updates these values so that:

- Keycloak accepts OAuth redirects back to the correct host
- CORS headers include the correct origin
- The Keycloak login and account pages link back to the correct application URL
- The realm's OpenID Connect discovery document advertises the correct issuer

This makes the image portable — the same build works for local development,
staging, and production by setting `SERVER_HOST` in the deployment environment.

### Environment Variables

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `KEYCLOAK_ADMIN` | Yes | `admin` | Admin username for kcadm authentication |
| `KEYCLOAK_ADMIN_PASSWORD` | Yes | `password` | Admin password for kcadm authentication |
| `KC_HTTP_RELATIVE_PATH` | Yes | *(none)* | Keycloak's HTTP relative path (e.g. `/keycloak`) |
| `SERVER_HOST` | No | *(none)* | Public hostname; when set, client URIs and the realm frontend URL are updated to match |

## Roles

The realm defines a single application-level role on the `webprotege`
client: **`SystemAdmin`**.  This is the bootstrap admin role for new
installs — assigning it to a user grants full administrative access to
WebProtege (manage application settings, create projects, edit roles,
delete accounts, etc.).

See the [webprotege-deploy README](../webprotege-deploy/README.md#first-admin-bootstrap)
for step-by-step instructions on assigning the role to the first admin.

All other authorization in WebProtege is managed inside the application
itself via the authorization service's `RoleAssignment` collection and
the Application Settings UI.  Keycloak roles are used only for the
bootstrap admin — this keeps identity (Keycloak) and authorization
(WebProtege) cleanly separated.

Automating the initial admin assignment on fresh installs is tracked in
[webprotege-authorization-service#36](https://github.com/protegeproject/webprotege-authorization-service/issues/36).

## Deployment

For full deployment instructions, see the [webprotege-deploy README](../webprotege-deploy/README.md).

## SMTP Configuration

The realm requires an SMTP server for the migrated user password reset flow. In development, Mailpit is used (configured in the `webprotege-deploy` Docker Compose). The SMTP settings are defined in the realm JSON under `smtpServer`.
