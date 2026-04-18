#!/bin/bash
# =============================================================================
# Integration Test for the WebProtege Keycloak Entrypoint
# =============================================================================
#
# This script verifies that the custom entrypoint (entrypoint.sh) correctly:
#
#   1. Imports the 'webprotege' realm on first boot.
#   2. Configures the 'username' protocol mapper to map the custom user
#      attribute 'webprotege_username' to the JWT claim 'preferred_username'.
#   3. Rewrites client redirect URIs, web origins, base URL, and the realm
#      frontend URL to match the SERVER_HOST environment variable.
#   4. Behaves idempotently on restart — skips realm import when the realm
#      already exists, skips mapper fix when already correct, and re-applies
#      URI updates harmlessly.
#
# PREREQUISITES
# -------------
#   - Docker daemon running
#   - jq installed on the host (used to parse kcadm JSON responses)
#   - The Docker image must be built before running this script:
#       docker build -t protegeproject/webprotege-keycloak:test .
#
# USAGE
# -----
#   ./test-entrypoint.sh [image]
#
#   image — Docker image to test (default: protegeproject/webprotege-keycloak:test)
#
# EXIT CODES
# ----------
#   0 — All tests passed
#   1 — One or more tests failed
#
# CLEANUP
# -------
#   The script removes its container and volume on exit (including on failure
#   or Ctrl+C) via a trap handler.  If you need to inspect a failed container,
#   comment out the cleanup() call in the trap.
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

IMAGE="${1:-protegeproject/webprotege-keycloak:test}"
CONTAINER_NAME="keycloak-entrypoint-test"
VOLUME_NAME="keycloak-entrypoint-test-data"
TEST_HOST="test.example.com"

# Keycloak admin credentials — must match the defaults in entrypoint.sh
KC_ADMIN="admin"
KC_ADMIN_PW="password"
KC_RELATIVE_PATH="/keycloak"

# How long to wait for the entrypoint to complete before failing (seconds)
TIMEOUT=120

# ---------------------------------------------------------------------------
# Colours for test output (disabled if stdout is not a terminal)
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  GREEN='' RED='' YELLOW='' NC=''
fi

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# cleanup
#
# Removes the test container and volume.  Called automatically on exit via
# trap, ensuring resources are freed even when a test fails or the script
# is interrupted.
# ---------------------------------------------------------------------------
cleanup() {
  echo ""
  echo "Cleaning up..."
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME_NAME" >/dev/null 2>&1 || true
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

# assert_eq <description> <expected> <actual>
#
# Compares two values and reports pass/fail.  On failure, prints both values
# so you can see what went wrong without re-running.
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo -e "        expected: ${expected}"
    echo -e "        actual:   ${actual}"
    FAIL=$((FAIL + 1))
  fi
}

# assert_contains <description> <substring> <haystack>
#
# Checks that a string contains the expected substring.  Useful for
# assertions on multi-line output where exact matching is fragile.
assert_contains() {
  local desc="$1" substring="$2" haystack="$3"
  if echo "$haystack" | grep -q "$substring"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo -e "        expected to contain: ${substring}"
    echo -e "        actual output:       ${haystack}"
    FAIL=$((FAIL + 1))
  fi
}

# wait_for_entrypoint
#
# Blocks until the entrypoint prints its completion message, or until
# TIMEOUT seconds have elapsed.  Returns 0 on success, 1 on timeout.
wait_for_entrypoint() {
  local elapsed=0
  while [ $elapsed -lt $TIMEOUT ]; do
    if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "\[entrypoint\] Realm configuration complete"; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo -e "${RED}ERROR: Entrypoint did not complete within ${TIMEOUT}s${NC}"
  echo "Container logs:"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -30
  return 1
}

# wait_for_entrypoint_count <n>
#
# Blocks until the entrypoint completion message has appeared at least <n>
# times in the container logs.  Used after a restart to wait for the second
# boot's entrypoint to finish.
wait_for_entrypoint_count() {
  local target="$1" elapsed=0
  while [ $elapsed -lt $TIMEOUT ]; do
    local count
    count=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -c "\[entrypoint\] Realm configuration complete" || true)
    if [ "$count" -ge "$target" ]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo -e "${RED}ERROR: Entrypoint completion #${target} not reached within ${TIMEOUT}s${NC}"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -30
  return 1
}

# kcadm <args...>
#
# Runs a kcadm.sh command inside the test container.  Authenticates against
# the master realm first (kcadm requires a session per invocation when run
# via docker exec without a persistent kcadm config directory).
kcadm() {
  docker exec "$CONTAINER_NAME" /opt/keycloak/bin/kcadm.sh \
    config credentials \
    --server "http://localhost:8080${KC_RELATIVE_PATH}" \
    --realm master \
    --user "$KC_ADMIN" \
    --password "$KC_ADMIN_PW" 2>/dev/null

  docker exec "$CONTAINER_NAME" /opt/keycloak/bin/kcadm.sh "$@"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

echo "=== Preflight checks ==="

# Verify jq is available on the host
if ! command -v jq &>/dev/null; then
  echo -e "${RED}ERROR: jq is required but not installed.${NC}"
  echo "Install it with: brew install jq (macOS) or apt install jq (Debian/Ubuntu)"
  exit 1
fi

# Verify the Docker image exists
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo -e "${RED}ERROR: Docker image '${IMAGE}' not found.${NC}"
  echo "Build it first with: docker build -t ${IMAGE} ."
  exit 1
fi

echo -e "  Image: ${IMAGE}"
echo -e "  Test host: ${TEST_HOST}"
echo ""

# ===========================================================================
# TEST PHASE 1: First boot
# ===========================================================================

echo "=== Phase 1: First boot ==="
echo "Starting container..."

# Remove any leftovers from a previous failed run
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker volume rm "$VOLUME_NAME" >/dev/null 2>&1 || true

# Start with a named volume so data persists across the restart in Phase 2.
# No host port is published — all kcadm assertions run inside the container
# via 'docker exec', so there is no port conflict risk on the host.
# SERVER_HOST is set to our test hostname so the URI patching runs.
docker run -d \
  --name "$CONTAINER_NAME" \
  -v "${VOLUME_NAME}:/opt/keycloak/data" \
  -e KEYCLOAK_ADMIN="$KC_ADMIN" \
  -e KEYCLOAK_ADMIN_PASSWORD="$KC_ADMIN_PW" \
  -e KC_HTTP_RELATIVE_PATH="$KC_RELATIVE_PATH" \
  -e SERVER_HOST="$TEST_HOST" \
  "$IMAGE" \
  start >/dev/null

echo "Waiting for entrypoint to complete..."
if ! wait_for_entrypoint; then
  exit 1
fi

# --- Check entrypoint log messages ---

LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
ENTRYPOINT_LOGS=$(echo "$LOGS" | grep "\[entrypoint\]")

echo ""
echo "--- Entrypoint log assertions ---"

assert_contains \
  "Realm was imported on first boot" \
  "Realm 'webprotege' imported successfully" \
  "$ENTRYPOINT_LOGS"

assert_contains \
  "Entrypoint completed" \
  "Realm configuration complete" \
  "$ENTRYPOINT_LOGS"

# --- Check the username protocol mapper ---
#
# The mapper in the 'profile' client scope should map the custom user
# attribute 'webprotege_username' to the 'preferred_username' JWT claim
# using the 'oidc-usermodel-attribute-mapper' protocol mapper type.

echo ""
echo "--- Mapper assertions ---"

PROFILE_SCOPE_ID=$(kcadm get client-scopes -r webprotege --fields id,name \
  | jq -r '.[] | select(.name == "profile") | .id')

MAPPER_ID=$(kcadm get "client-scopes/$PROFILE_SCOPE_ID/protocol-mappers/models" \
  -r webprotege --fields id,name \
  | jq -r '.[] | select(.name == "username") | .id')

MAPPER_JSON=$(kcadm get \
  "client-scopes/$PROFILE_SCOPE_ID/protocol-mappers/models/$MAPPER_ID" \
  -r webprotege)

assert_eq \
  "Mapper type is oidc-usermodel-attribute-mapper" \
  "oidc-usermodel-attribute-mapper" \
  "$(echo "$MAPPER_JSON" | jq -r '.protocolMapper')"

assert_eq \
  "Mapper user.attribute is webprotege_username" \
  "webprotege_username" \
  "$(echo "$MAPPER_JSON" | jq -r '.config["user.attribute"]')"

assert_eq \
  "Mapper claim.name is preferred_username" \
  "preferred_username" \
  "$(echo "$MAPPER_JSON" | jq -r '.config["claim.name"]')"

# --- Check client URIs ---
#
# The 'webprotege' client's baseUrl, redirectUris, and webOrigins should
# all reference the TEST_HOST hostname, not the hardcoded default from
# the realm JSON.

echo ""
echo "--- Client URI assertions ---"

CLIENT_ID=$(kcadm get clients -r webprotege --fields id,clientId \
  | jq -r '.[] | select(.clientId == "webprotege") | .id')

CLIENT_JSON=$(kcadm get "clients/$CLIENT_ID" \
  -r webprotege --fields baseUrl,redirectUris,webOrigins)

assert_eq \
  "Client baseUrl uses SERVER_HOST" \
  "http://${TEST_HOST}" \
  "$(echo "$CLIENT_JSON" | jq -r '.baseUrl')"

assert_contains \
  "Client redirectUris includes SERVER_HOST wildcard" \
  "http://${TEST_HOST}/*" \
  "$(echo "$CLIENT_JSON" | jq -r '.redirectUris[]')"

assert_contains \
  "Client webOrigins includes SERVER_HOST" \
  "http://${TEST_HOST}/webprotege" \
  "$(echo "$CLIENT_JSON" | jq -r '.webOrigins[]')"

# --- Check realm frontend URL ---

echo ""
echo "--- Realm frontend URL assertion ---"

FRONTEND_URL=$(kcadm get realms/webprotege --fields 'attributes(frontendUrl)' \
  | jq -r '.attributes.frontendUrl')

assert_eq \
  "Realm frontendUrl uses SERVER_HOST" \
  "http://${TEST_HOST}/keycloak" \
  "$FRONTEND_URL"

# ===========================================================================
# TEST PHASE 2: Restart (idempotency)
# ===========================================================================

echo ""
echo "=== Phase 2: Restart (idempotency) ==="
echo "Restarting container..."

docker restart "$CONTAINER_NAME" >/dev/null

echo "Waiting for entrypoint to complete (second boot)..."
if ! wait_for_entrypoint_count 2; then
  exit 1
fi

# The entrypoint messages from the second boot are interleaved with the
# first boot's messages in the Docker log.  We extract only the messages
# from after the restart by finding everything after the last "Waiting
# for Keycloak to start" message.  The awk command resets its buffer
# each time it sees the marker, so at the end only the final block
# (the second boot) remains.
SECOND_BOOT_LOGS=$(docker logs "$CONTAINER_NAME" 2>&1 \
  | grep "\[entrypoint\]" \
  | awk '/Waiting for Keycloak to start/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}')

echo ""
echo "--- Idempotency assertions ---"

assert_contains \
  "Realm import was skipped on restart" \
  "already exists" \
  "$SECOND_BOOT_LOGS"

assert_contains \
  "Mapper fix was skipped on restart" \
  "already correct" \
  "$SECOND_BOOT_LOGS"

assert_contains \
  "Entrypoint completed on restart" \
  "Realm configuration complete" \
  "$SECOND_BOOT_LOGS"

# --- Verify state is still correct after restart ---
#
# Re-check the mapper and URIs to confirm the restart did not corrupt
# or revert any configuration.

echo ""
echo "--- Post-restart state assertions ---"

# Re-authenticate (session from Phase 1 may have expired)
MAPPER_JSON_2=$(kcadm get \
  "client-scopes/$PROFILE_SCOPE_ID/protocol-mappers/models/$MAPPER_ID" \
  -r webprotege)

assert_eq \
  "Mapper still correct after restart" \
  "webprotege_username" \
  "$(echo "$MAPPER_JSON_2" | jq -r '.config["user.attribute"]')"

CLIENT_JSON_2=$(kcadm get "clients/$CLIENT_ID" \
  -r webprotege --fields baseUrl)

assert_eq \
  "Client baseUrl still correct after restart" \
  "http://${TEST_HOST}" \
  "$(echo "$CLIENT_JSON_2" | jq -r '.baseUrl')"

FRONTEND_URL_2=$(kcadm get realms/webprotege --fields 'attributes(frontendUrl)' \
  | jq -r '.attributes.frontendUrl')

assert_eq \
  "Realm frontendUrl still correct after restart" \
  "http://${TEST_HOST}/keycloak" \
  "$FRONTEND_URL_2"

# ===========================================================================
# Results
# ===========================================================================

echo ""
echo "==========================================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}All ${TOTAL} tests passed.${NC}"
  exit 0
else
  echo -e "${RED}${FAIL} of ${TOTAL} tests failed.${NC}"
  exit 1
fi
