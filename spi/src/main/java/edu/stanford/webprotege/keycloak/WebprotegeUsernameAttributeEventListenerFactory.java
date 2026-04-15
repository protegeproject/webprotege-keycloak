package edu.stanford.webprotege.keycloak;

import org.keycloak.Config;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventListenerProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

/**
 * Factory that creates {@link WebprotegeUsernameAttributeEventListener} instances.
 *
 * <p>Registered via {@code META-INF/services/org.keycloak.events.EventListenerProviderFactory}
 * so that Keycloak discovers it during startup.  This factory must be listed in
 * the realm's {@code eventsListeners} configuration (set in the realm JSON) for
 * the listener to receive events.
 */
public class WebprotegeUsernameAttributeEventListenerFactory implements EventListenerProviderFactory {

    public static final String PROVIDER_ID = "webprotege-username-attribute";

    @Override
    public EventListenerProvider create(KeycloakSession session) {
        return new WebprotegeUsernameAttributeEventListener(session);
    }

    @Override
    public void init(Config.Scope config) {
        // No configuration required.
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // Nothing to do after init.
    }

    @Override
    public void close() {
        // Nothing to clean up.
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }
}
