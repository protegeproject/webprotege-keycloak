package edu.stanford.webprotege.keycloak;

import org.keycloak.events.Event;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventType;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Event listener that populates the {@code webprotege_username} user attribute
 * on newly registered users.
 *
 * <p>Background: the WebProtege stack uses a custom protocol mapper that maps
 * the {@code webprotege_username} user attribute to the {@code preferred_username}
 * JWT claim.  The mapper was introduced to support legacy users migrated from
 * pre-Keycloak WebProtege — those users have their original MongoDB user ID
 * stored in the {@code webprotege_username} attribute, which the backend
 * services use for user lookup.
 *
 * <p>For newly registered Keycloak users the attribute does not exist, so the
 * {@code preferred_username} claim would be absent from the JWT.  The API
 * gateway requires this claim to identify the user and rejects requests without
 * it (returning a 400 Bad Request with a {@code User null} log line).
 *
 * <p>This listener watches for {@link EventType#REGISTER} events and sets the
 * {@code webprotege_username} attribute to the Keycloak username for any
 * newly registered user who does not already have the attribute.  Migrated
 * users are unaffected because their attribute is already populated.
 */
public class WebprotegeUsernameAttributeEventListener implements EventListenerProvider {

    private static final Logger logger = LoggerFactory.getLogger(
            WebprotegeUsernameAttributeEventListener.class);

    private static final String ATTRIBUTE_NAME = "webprotege_username";

    private final KeycloakSession session;

    public WebprotegeUsernameAttributeEventListener(KeycloakSession session) {
        this.session = session;
    }

    @Override
    public void onEvent(Event event) {
        if (event.getType() != EventType.REGISTER) {
            return;
        }

        String realmId = event.getRealmId();
        String userId = event.getUserId();
        if (realmId == null || userId == null) {
            return;
        }

        RealmModel realm = session.realms().getRealm(realmId);
        if (realm == null) {
            return;
        }

        UserModel user = session.users().getUserById(realm, userId);
        if (user == null) {
            return;
        }

        // Don't overwrite an existing value — migrated users may already have
        // this attribute set to their legacy MongoDB user ID.
        String existing = user.getFirstAttribute(ATTRIBUTE_NAME);
        if (existing != null && !existing.isEmpty()) {
            return;
        }

        String username = user.getUsername();
        if (username == null || username.isEmpty()) {
            logger.warn("Registered user {} has no username; cannot set {} attribute",
                    userId, ATTRIBUTE_NAME);
            return;
        }

        user.setSingleAttribute(ATTRIBUTE_NAME, username);
        logger.info("Set {}={} on newly registered user {}", ATTRIBUTE_NAME, username, userId);
    }

    @Override
    public void onEvent(AdminEvent event, boolean includeRepresentation) {
        // Not interested in admin events.
    }

    @Override
    public void close() {
        // Nothing to clean up.
    }
}
