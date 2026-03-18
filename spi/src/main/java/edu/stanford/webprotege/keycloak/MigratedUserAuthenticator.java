package edu.stanford.webprotege.keycloak;

import jakarta.ws.rs.core.MultivaluedMap;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.actiontoken.resetcred.ResetCredentialsActionToken;
import org.keycloak.authentication.authenticators.browser.UsernamePasswordForm;
import org.keycloak.common.util.Time;
import org.keycloak.models.credential.PasswordCredentialModel;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.utils.FormMessage;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.sessions.AuthenticationSessionCompoundId;
import org.keycloak.sessions.AuthenticationSessionModel;

import java.util.concurrent.TimeUnit;

public class MigratedUserAuthenticator extends UsernamePasswordForm {

    @Override
    public void action(AuthenticationFlowContext context) {
        MultivaluedMap<String, String> formData = context.getHttpRequest().getDecodedFormParameters();
        String username = formData.getFirst("username");

        KeycloakSession session = context.getSession();
        RealmModel realm = context.getRealm();

        UserModel user = session.users().getUserByUsername(realm, username);
        if (user == null) {
            user = session.users().getUserByEmail(realm, username);
        }

        if (user == null) {
            super.action(context);
            return;
        }

        boolean hasPassword = user.credentialManager()
                .getStoredCredentialsByTypeStream(PasswordCredentialModel.TYPE)
                .findAny()
                .isPresent();

        if (!hasPassword) {
            sendPasswordResetEmail(context, user);
            return;
        }

        // User has a password — delegate to built-in validation
        super.action(context);
    }

    private void sendPasswordResetEmail(AuthenticationFlowContext context, UserModel user) {
        KeycloakSession session = context.getSession();
        RealmModel realm = context.getRealm();
        AuthenticationSessionModel authSession = context.getAuthenticationSession();

        int lifespan = realm.getActionTokenGeneratedByUserLifespan();

        String authSessionEncodedId = AuthenticationSessionCompoundId
                .fromAuthSession(authSession).getEncodedId();

        ResetCredentialsActionToken token = new ResetCredentialsActionToken(
                user.getId(),
                user.getEmail(),
                Time.currentTime() + lifespan,
                authSessionEncodedId,
                authSession.getClient().getClientId()
        );

        String link = context.getActionTokenUrl(
                token.serialize(session, realm, context.getUriInfo())
        ).toString();

        try {
            session.getProvider(EmailTemplateProvider.class)
                    .setRealm(realm)
                    .setUser(user)
                    .sendPasswordReset(link, TimeUnit.SECONDS.toMinutes(lifespan));
        } catch (Exception e) {
            context.failureChallenge(AuthenticationFlowError.INTERNAL_ERROR,
                    context.form()
                            .setError("emailSendError")
                            .createLoginUsernamePassword());
            return;
        }

        context.forkWithSuccessMessage(new FormMessage("migratedUserResetMessage"));
    }
}
