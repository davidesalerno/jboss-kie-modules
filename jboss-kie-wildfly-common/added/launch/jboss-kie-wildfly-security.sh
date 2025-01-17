#!/bin/bash

source "${JBOSS_HOME}/bin/launch/launch-common.sh"
source "${JBOSS_HOME}/bin/launch/logging.sh"

########## Environment Variables ##########

function unset_kie_security_env() {
    # please keep these in alphabetical order
    unset APPLICATION_USERS_PROPERTIES
    unset APPLICATION_ROLES_PROPERTIES
    unset KIE_ADMIN_PWD
    unset KIE_ADMIN_ROLES
    unset KIE_ADMIN_USER
    unset KIE_SERVER_BYPASS_AUTH_USER
    unset KIE_SERVER_CONTROLLER_TOKEN
    unset KIE_SERVER_DOMAIN
    unset KIE_SERVER_ROLES
    unset KIE_SERVER_TOKEN
}

########## Defaults ##########

function get_default_kie_user() {
    local kie_type="${1}"
    echo "${kie_type}User"
}

function get_default_kie_pwd() {
    local kie_type="${1}"
    echo "${kie_type}1!"
}

function esc_kie_pwd() {
    local kie_pwd="${1}"
    echo ${kie_pwd//\"/\\\"}
}

########## KIE Admin ##########

function get_kie_admin_user() {
    local default_kie_user=$(get_default_kie_user "admin")
    echo $(find_env "KIE_ADMIN_USER" "${default_kie_user}")
}

function get_kie_admin_pwd() {
    local default_kie_pwd=$(get_default_kie_pwd "admin")
    echo $(find_env "KIE_ADMIN_PWD" "${default_kie_pwd}")
}

function esc_kie_admin_pwd() {
    local orig_kie_pwd=$(get_kie_admin_pwd)
    echo $(esc_kie_pwd "${orig_kie_pwd}")
}

function get_kie_admin_roles() {
    local default_kie_roles="kie-server,rest-all,admin,kiemgmt,Administrators,user"
    echo $(find_env "KIE_ADMIN_ROLES" "${default_kie_roles}")
}

function add_kie_admin_user() {
    add_eap_user "admin" "$(get_kie_admin_user)" "$(get_kie_admin_pwd)" "$(get_kie_admin_roles)"
    migrate_users_from_properties_to_elytron_fs
}

########## KIE Server ##########

function get_kie_server_token() {
    local default_kie_token=""
    echo $(find_env "KIE_SERVER_TOKEN" "${default_kie_token}")
}

function get_kie_server_domain() {
    local default_kie_domain="other"
    if [ "${AUTH_LDAP_URL}x" != "x" ]; then
        default_kie_domain="KIELdapSecurityDomain"
    fi
    local domain=$(find_env "KIE_SERVER_DOMAIN" "${default_kie_domain}")
    if [ "${domain}" != "other" ] && [ "${domain}" != "KIELdapSecurityDomain" ]; then
        export SECDOMAIN_NAME="${domain}"
        export ELYTRON_SECDOMAIN_NAME="${domain}"
    fi
    echo "${domain}"
}

function get_kie_server_bypass_auth_user() {
    local bypass_auth_user=$(echo "${KIE_SERVER_BYPASS_AUTH_USER}" | tr "[:upper:]" "[:lower:]")
    if [ "x${bypass_auth_user}" != "x" ] && [ "${bypass_auth_user}" != "true" ]; then
        bypass_auth_user="false"
    fi
    echo "${bypass_auth_user}"
}

########## KIE Server Controller ##########

function get_kie_server_controller_token() {
    local default_kie_token=""
    echo $(find_env "KIE_SERVER_CONTROLLER_TOKEN" "${default_kie_token}")
}

########## EAP ##########

function get_application_config() {
    local props_file="${1}"
    local default_file="${2}"
    local default_content="${3}"
    if [ "x${props_file}" = "x" ]; then
        props_file="${JBOSS_HOME}/standalone/configuration/${default_file}"
    fi
    local props_dir=$(dirname "${props_file}")
    if [ ! -e "${props_dir}" ]; then
        mkdir -p "${props_dir}"
    fi
    if [ ! -f "${props_file}" ]; then
        if [ "x${default_content}" = "x" ]; then
            touch "${props_file}"
        else
            echo "${default_content}" > "${props_file}"
        fi
    fi
    echo "${props_file}"
}

function get_application_users_properties() {
    local application_users_properties=$(get_application_config "${APPLICATION_USERS_PROPERTIES}" "application-users.properties" '#$REALM_NAME=ApplicationRealm$')
    echo "${application_users_properties}"
}

function get_application_roles_properties() {
    echo $(get_application_config "${APPLICATION_ROLES_PROPERTIES}" "application-roles.properties")
}

function migrate_users_from_properties_to_elytron_fs() {
    if [ "${AUTH_LDAP_URL}x" == "x" ] && [ "${SSO_URL}x" == "x" ] || [ "${AUTH_LDAP_LOGIN_FAILOVER^^}" == "TRUE" ] || [ "${AUTH_LDAP_LOGIN_MODULE}" == "optional" ]; then
        local opts=""
        if [ "${SCRIPT_DEBUG}" = "true" ] ; then
            opts="--debug"
        fi
        log_info "Migrating users to elytron kie-filesystem-realm $(get_kie_fs_path)."
        $JBOSS_HOME/bin/elytron-tool.sh filesystem-realm \
            --users-file $(get_application_users_properties) \
            --roles-file $(get_application_roles_properties) \
            --output-location $(get_kie_fs_path) ${opts}

        # TODO workaround to rename roles to role so business central can understand it.
        # when fixed on BC or wfly code base we can remove it
        find $(get_kie_fs_path) -name *.xml -exec sed -i 's/<attribute name="roles"/<attribute name="role"/g' {} \;
    fi
}

function add_eap_user() {
    # If LDAP/SSO integration is enabled do not create eap users.
    # even if ldap url is set, create the KIE_ADMIN_USER for failover to FsRealm
    if [ "${AUTH_LDAP_URL}x" == "x" ] && [ "${SSO_URL}x" == "x" ] || [ "${AUTH_LDAP_LOGIN_FAILOVER^^}" == "TRUE" ] || [ "${AUTH_LDAP_LOGIN_MODULE}" == "optional" ]; then
        local kie_type="${1}"
        local eap_user="${2}"
        local eap_pwd="${3}"
        local eap_roles="${4}"
        local application_users_properties="$(get_application_users_properties)"
        local application_roles_properties="$(get_application_roles_properties)"
        local current_admin_user_file=$(dirname "${application_users_properties}")/current-admin-user
        if (grep "^${eap_user}=" "${application_users_properties}" > /dev/null 2>&1); then
            log_warning "KIE ${kie_type} user \"${eap_user}\" already exists in EAP, user will be updated if changes were made."
        else
            # if there are any user persisted saved previously, let's remove it from user properties
            local old_user=$(cat ${current_admin_user_file} 2> /dev/null)
            if [[ -f "${current_admin_user_file}" ]] && [[ "${old_user}" != "${eap_user}" ]]; then
                log_info "User \"${old_user}\" will be removed, new user \"${eap_user}\"."
                sed -i "/^$old_user/ d" "${application_users_properties}"
                sed -i "/^$old_user/ d" "${application_roles_properties}"
            fi
         fi

        local add_user_args=(
            "-a"
            "--user" "'${eap_user}'"
            "--password" "'${eap_pwd}'"
        )
        add_user_args+=( "--user-properties" "'${application_users_properties}'" )
        add_user_args+=( "--group-properties" "'${application_roles_properties}'" )
        if [ "x${eap_roles}" != "x" ]; then
            add_user_args+=( "--role" "${eap_roles}" )
        fi
        eval "${JBOSS_HOME}/bin/add-user.sh ${add_user_args[@]}"
        if [ "$?" -ne "0" ]; then
           log_error "Failed to add KIE ${kie_type} user \"${eap_user}\" in EAP"
           log_error "Exiting..."
           exit
        fi

        # save current admin user
        echo $KIE_ADMIN_USER > ${current_admin_user_file}
    else
        print_external_user_information
    fi
}

# print information if the users creation is skipped
# This function only have the purpose to print user information to guide the user about what
# users they need to create on the external auth provider when enabled.
print_external_user_information() {
    log_info "External authentication/authorization enabled, skipping the embedded users creation."
    if [ "${KIE_ADMIN_USER}x" != "x" ]; then
            log_info "KIE_ADMIN_USER is set to ${KIE_ADMIN_USER}, make sure to configure this user with the provided password on the external auth provider with the roles $(get_kie_admin_roles)"
    else
        log_info "Make sure to configure KIE_ADMIN_USER user to access the application with the roles $(get_kie_admin_roles)"
    fi
}

