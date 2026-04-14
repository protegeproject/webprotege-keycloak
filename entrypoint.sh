#!/bin/bash
# =============================================================================
# WebProtege Keycloak Entrypoint
# =============================================================================
#
# This script wraps the standard Keycloak startup to apply realm configuration
# fixes that cannot be achieved through the normal realm import mechanism alone.
#
# WHY THIS EXISTS
# ---------------
# WebProtege ships a realm JSON file (webprotege.json) that is imported
# automatically by Keycloak on first boot via the /opt/keycloak/import/
# directory.  Two problems prevent the imported realm from being correct
# out of the box:
#
#   1. PROTOCOL MAPPER BUG — Keycloak's realm import silently drops the
#      'config' dictionary for certain protocol mapper types.  The realm
#      JSON defines a 'username' mapper in the 'profile' client scope that
#      maps the custom user attribute 'webprotege_username' to the JWT claim
#      'preferred_username'.  After import, Keycloak reverts this mapper to
#      its built-in default, which maps the Keycloak username field instead.
#
#      This matters because WebProtege uses email addresses as Keycloak
#      usernames, but internal application lookups rely on the original
#      MongoDB user ID stored in the 'webprotege_username' attribute.
#      Without this fix, the backend receives email addresses where it
#      expects user IDs, breaking user resolution.
#
#      See also:
#        https://github.com/keycloak/keycloak/issues/36065
#          (client scope PUT silently ignores protocolMappers — by design)
#        https://github.com/keycloak/keycloak/issues/16289
#          (partial realm import ignores clientScopes entirely — still open)
#
#   2. HARDCODED HOSTNAMES — The realm JSON contains client redirect URIs,
#      web origins, and a realm-level frontend URL that reference a specific
#      hostname (e.g. 'webprotege-local.edu').  Self-hosted deployments use
#      different hostnames.  Rather than requiring operators to manually edit
#      the realm JSON or run kcadm commands after startup, this script reads
#      the SERVER_HOST environment variable and patches these values
#      automatically, making the image portable across environments.
#
# HOW IT WORKS
# ------------
#   1. Keycloak is started in the background (the normal kc.sh process).
#   2. The script waits for Keycloak to become healthy by authenticating
#      to the Admin CLI against the master realm.
#   3. It checks whether the 'webprotege' realm exists.  If not, it
#      imports it from the baked-in realm JSON via kcadm.  (Keycloak does
#      not auto-import from /opt/keycloak/import/ — only from
#      /opt/keycloak/data/import/ with the --import-realm flag.  We use
#      explicit kcadm import for full control over the process.)
#   4. It checks and, if necessary, fixes the username protocol mapper.
#   5. If SERVER_HOST is set, it updates client URIs and the realm frontend
#      URL to match.
#   6. Control is handed back to the Keycloak process, which remains the
#      container's foreground process for the rest of its lifecycle.
#
# IDEMPOTENCY
# -----------
# Every patch is guarded by a check.  On subsequent container restarts
# (where the realm already exists in Keycloak's persistent storage and the
# mapper was fixed on a previous boot), the script detects the correct state
# and skips the modification.  This means the script is safe to run on every
# startup without side effects.
#
# SIGNAL HANDLING
# ---------------
# SIGTERM and SIGINT are forwarded to the Keycloak background process so
# that 'docker compose stop' triggers a graceful Keycloak shutdown rather
# than killing the wrapper script and orphaning the Java process.
#
# REQUIRED ENVIRONMENT VARIABLES
# ------------------------------
#   KEYCLOAK_ADMIN          — Admin username (default: 'admin')
#   KEYCLOAK_ADMIN_PASSWORD — Admin password (default: 'password')
#   KC_HTTP_RELATIVE_PATH   — Keycloak's HTTP relative path, used to
#                             construct the admin server URL (e.g. '/keycloak')
#
# OPTIONAL ENVIRONMENT VARIABLES
# ------------------------------
#   SERVER_HOST — The public hostname for this deployment (e.g.
#                 'webproteg.local', 'webprotege.example.org').  When set,
#                 the script updates the 'webprotege' client's redirect URIs,
#                 web origins, base URL, and the realm's frontend URL to
#                 match.  When omitted, URI patching is skipped and the
#                 realm retains whatever values it was imported with.
#
# DEPENDENCIES
# ------------
#   jq — Installed in the Docker image via a multi-stage build that
#        downloads the static binary from the jq GitHub releases.  Used
#        to parse JSON responses from kcadm.sh when extracting IDs and
#        checking config.
#
# =============================================================================

set -euo pipefail

KCADM="/opt/keycloak/bin/kcadm.sh"
KC_RELATIVE_PATH="${KC_HTTP_RELATIVE_PATH:-}"
KC_SERVER="http://localhost:8080${KC_RELATIVE_PATH}"
KC_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KC_ADMIN_PW="${KEYCLOAK_ADMIN_PASSWORD:-password}"

# If no command is provided (e.g. compose omits the 'command' directive),
# default to 'start-dev' which is the standard Keycloak development mode.
if [ $# -eq 0 ]; then
  set -- start-dev
fi

# ---------------------------------------------------------------------------
# Start Keycloak in the background.
#
# The arguments ($@) are passed through from Docker — typically 'start-dev'
# via the compose command directive.  Running in the background allows this
# script to perform post-import patching while Keycloak is initialising.
# ---------------------------------------------------------------------------
/opt/keycloak/bin/kc.sh "$@" &
KC_PID=$!

# Forward SIGTERM/SIGINT to the Keycloak process.  Without this, Docker's
# stop signal would kill the wrapper script but leave the Java process
# running until the container is forcefully terminated.
trap 'kill -TERM $KC_PID 2>/dev/null; wait $KC_PID; exit $?' TERM INT

# ---------------------------------------------------------------------------
# Wait for Keycloak to be ready.
#
# We wait for the Keycloak HTTP server to be accepting admin API requests.
# The check authenticates against the master realm — once this succeeds we
# know the server is fully initialised and can accept kcadm commands.
#
# The loop retries every 2 seconds for up to MAX_RETRIES attempts.  If
# Keycloak fails to start in time, the script logs an error but does NOT
# crash the container — Keycloak continues running, just without the realm
# setup.
# ---------------------------------------------------------------------------
echo "[entrypoint] Waiting for Keycloak to start..."
MAX_RETRIES=60
RETRY=0
until $KCADM config credentials \
        --server "$KC_SERVER" \
        --realm master \
        --user "$KC_ADMIN" \
        --password "$KC_ADMIN_PW" 2>/dev/null; do
  RETRY=$((RETRY + 1))
  if [ $RETRY -ge $MAX_RETRIES ]; then
    echo "[entrypoint] ERROR: Keycloak did not become ready within $((MAX_RETRIES * 2))s."
    echo "[entrypoint] Realm setup has been skipped.  Keycloak will continue running"
    echo "[entrypoint] but the webprotege realm may be missing or misconfigured."
    echo "[entrypoint] Check the Keycloak logs above for startup errors."
    wait $KC_PID
    exit $?
  fi
  sleep 2
done

echo "[entrypoint] Keycloak is ready."

# ---------------------------------------------------------------------------
# Import the webprotege realm if it does not already exist.
#
# The realm JSON is baked into the image at /opt/keycloak/import/.  Keycloak
# does NOT auto-import from this path — the file is imported explicitly here
# via kcadm on first boot.  On subsequent boots (where the realm already
# exists in Keycloak's persistent H2 database), this step is skipped.
# ---------------------------------------------------------------------------
REALM_JSON="/opt/keycloak/import/webprotege.json"

if $KCADM get realms/webprotege >/dev/null 2>&1; then
  echo "[entrypoint] Realm 'webprotege' already exists. Skipping import."
else
  echo "[entrypoint] Realm 'webprotege' not found. Importing from ${REALM_JSON}..."
  if [ ! -f "$REALM_JSON" ]; then
    echo "[entrypoint] ERROR: Realm file not found at ${REALM_JSON}. Cannot import."
    wait $KC_PID
    exit $?
  fi
  $KCADM create realms -f "$REALM_JSON"
  echo "[entrypoint] Realm 'webprotege' imported successfully."
fi

echo "[entrypoint] Checking realm configuration..."

# ---------------------------------------------------------------------------
# fix_username_mapper
#
# Detects and fixes the 'username' protocol mapper in the 'profile' client
# scope.  See the "PROTOCOL MAPPER BUG" section in the header for context.
#
# Steps:
#   1. Look up the internal ID of the 'profile' client scope.
#   2. Within that scope, look up the internal ID of the 'username' mapper.
#   3. Read the mapper's current config and check whether 'user.attribute'
#      is already set to 'webprotege_username'.
#   4. If yes  -> do nothing (already correct, either from a previous boot
#                 or because a future Keycloak version fixes the import bug).
#      If no   -> delete the broken mapper and recreate it with the correct
#                 configuration.
#
# The delete-then-create approach (rather than an in-place update) is used
# because kcadm does not reliably support partial updates to protocol mapper
# config fields.
# ---------------------------------------------------------------------------
fix_username_mapper() {
  local scope_id mapper_id current_attr

  # Step 1: Find the 'profile' client scope ID
  scope_id=$($KCADM get client-scopes -r webprotege --fields id,name \
    | jq -r '.[] | select(.name == "profile") | .id')

  if [ -z "$scope_id" ]; then
    echo "[entrypoint] WARNING: 'profile' client scope not found. Skipping mapper fix."
    return
  fi

  # Step 2: Find the 'username' mapper ID within the profile scope
  mapper_id=$($KCADM get "client-scopes/$scope_id/protocol-mappers/models" \
    -r webprotege --fields id,name \
    | jq -r '.[] | select(.name == "username") | .id')

  if [ -z "$mapper_id" ]; then
    echo "[entrypoint] WARNING: 'username' mapper not found in profile scope. Skipping."
    return
  fi

  # Step 3: Check current state — skip if already correct
  current_attr=$($KCADM get \
    "client-scopes/$scope_id/protocol-mappers/models/$mapper_id" \
    -r webprotege | jq -r '.config["user.attribute"] // empty')

  if [ "$current_attr" = "webprotege_username" ]; then
    echo "[entrypoint] Username mapper already correct. Skipping."
    return
  fi

  # Step 4: Delete the broken mapper and recreate with the correct config
  echo "[entrypoint] Fixing username mapper (current user.attribute: '${current_attr:-<empty>}')..."

  $KCADM delete \
    "client-scopes/$scope_id/protocol-mappers/models/$mapper_id" \
    -r webprotege

  $KCADM create \
    "client-scopes/$scope_id/protocol-mappers/models" \
    -r webprotege \
    -s name=username \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-usermodel-attribute-mapper \
    -s consentRequired=false \
    -s 'config."user.attribute"=webprotege_username' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."claim.name"=preferred_username' \
    -s 'config."jsonType.label"=String' \
    -s 'config."userinfo.token.claim"=true'

  echo "[entrypoint] Username mapper fixed successfully."
}

# ---------------------------------------------------------------------------
# update_client_uris
#
# Updates the 'webprotege' Keycloak client and the realm-level frontend URL
# to match the current SERVER_HOST value.  See the "HARDCODED HOSTNAMES"
# section in the header for context.
#
# The realm JSON ships with a default hostname baked into redirect URIs, web
# origins, and the base URL.  Self-hosted deployments will have a different
# hostname.  This function overwrites those values so that:
#
#   - Keycloak accepts OAuth redirects back to the correct host
#   - CORS headers include the correct origin
#   - The Keycloak account console and login pages link back to the correct
#     application URL
#
# This runs on every startup (not just first boot) because SERVER_HOST may
# change between restarts — e.g. switching from local dev to a staging
# hostname.  The kcadm 'update' command is a PUT, so applying the same
# values twice is harmless.
#
# Skipped entirely if SERVER_HOST is not set, allowing the realm to retain
# whatever values it was imported with.
# ---------------------------------------------------------------------------
update_client_uris() {
  if [ -z "${SERVER_HOST:-}" ]; then
    echo "[entrypoint] SERVER_HOST not set. Skipping client URI update."
    return
  fi

  local client_id

  # Find the internal ID of the 'webprotege' client
  client_id=$($KCADM get clients -r webprotege --fields id,clientId \
    | jq -r '.[] | select(.clientId == "webprotege") | .id')

  if [ -z "$client_id" ]; then
    echo "[entrypoint] WARNING: 'webprotege' client not found. Skipping URI update."
    return
  fi

  # Update the client's base URL, redirect URI whitelist, and allowed web origins
  echo "[entrypoint] Updating webprotege client URIs for SERVER_HOST=${SERVER_HOST}..."

  $KCADM update "clients/$client_id" -r webprotege \
    -s "baseUrl=http://${SERVER_HOST}" \
    -s "redirectUris=[\"http://${SERVER_HOST}/*\",\"http://${SERVER_HOST}/webprotege/*\"]" \
    -s "webOrigins=[\"http://${SERVER_HOST}/webprotege\"]"

  # Update the realm-level frontend URL.  This controls URLs that Keycloak
  # generates in emails, account console links, and the OpenID Connect
  # discovery document.
  echo "[entrypoint] Updating realm frontend URL..."
  $KCADM update realms/webprotege \
    -s "attributes.frontendUrl=http://${SERVER_HOST}/keycloak"

  echo "[entrypoint] Client URIs and frontend URL updated for ${SERVER_HOST}."
}

# ---------------------------------------------------------------------------
# Apply the patches and hand control back to Keycloak.
# ---------------------------------------------------------------------------
fix_username_mapper
update_client_uris

echo "[entrypoint] Realm configuration complete."

# Wait for the Keycloak process.  This keeps the script (and therefore the
# container) alive for as long as Keycloak is running.  When Keycloak exits
# (either normally or via the signal trap above), the script exits with
# Keycloak's exit code.
wait $KC_PID
