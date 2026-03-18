<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=false; section>
    <#if section = "header">
    <#elseif section = "form">
        <div class="wp-alert wp-alert-info">
            <span class="wp-alert-text">
                IMPORTANT NOTICE: Your account has been migrated to our new system.
                We've sent you an email to set your password. Please check your inbox.
            </span>
        </div>
        <p style="text-align: center; margin-top: 16px;">
            Once you've set your password,
            <a href="${url.loginUrl}">return to sign in</a>.
        </p>
    </#if>
</@layout.registrationLayout>
