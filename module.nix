{ config, lib, pkgs, ... }:

let
  sp = config.selfprivacy;
  cfg = sp.modules.paperless;

  dataDir = "/var/lib/paperless";
  port = 28981;

  auth-passthru = sp.passthru.auth or null;
  hasAuth = sp.sso.enable or false;

  oauthClientID = "paperless";
  adminsGroup = "sp.paperless.admins";
  usersGroup = "sp.paperless.users";

  ssoEnvFile = "/var/lib/paperless-sso-env";
in
{
  options.selfprivacy.modules.paperless = {
    enable = (lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Paperless-ngx";
    }) // { meta.type = "enable"; };

    location = (lib.mkOption {
      type = lib.types.str;
      description = "Volume for Paperless data";
    }) // { meta.type = "location"; };

    subdomain = (lib.mkOption {
      default = "paperless";
      type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9\\-]{0,61}[A-Za-z0-9]";
      description = "Subdomain for Paperless-ngx";
    }) // {
      meta = {
        widget = "subdomain";
        type = "string";
        regex = "[A-Za-z0-9][A-Za-z0-9\\-]{0,61}[A-Za-z0-9]";
        weight = 0;
      };
    };

    ocr-languages = (lib.mkOption {
      type = lib.types.str;
      default = "eng";
      description = "OCR language packs to install (e.g. \"eng+fra+deu\")";
    }) // { meta = { type = "string"; weight = 1; }; };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = sp.domain != null && sp.domain != "";
      message = "selfprivacy.domain must be set for the Paperless module.";
    }];

    fileSystems.${dataDir} = lib.mkIf sp.useBinds {
      device = "/volumes/${cfg.location}/paperless";
      options = [
        "bind"
        "x-systemd.required-by=paperless-web.service"
        "x-systemd.required-by=paperless-scheduler.service"
        "x-systemd.required-by=paperless-task-queue.service"
        "x-systemd.required-by=paperless-consumer.service"
        "x-systemd.before=paperless-web.service"
        "x-systemd.before=paperless-scheduler.service"
        "x-systemd.before=paperless-task-queue.service"
        "x-systemd.before=paperless-consumer.service"
      ];
    };

    system.activationScripts.paperless-setup = lib.stringAfter [ "users" ] (
      lib.optionalString sp.useBinds ''
        mkdir -p /volumes/${lib.escapeShellArg cfg.location}/paperless
        chown paperless:paperless /volumes/${lib.escapeShellArg cfg.location}/paperless
      ''
      + lib.optionalString hasAuth ''
        secret=$(cat ${lib.escapeShellArg (auth-passthru.mkOAuth2ClientSecretFP oauthClientID)})
        printf 'PAPERLESS_SOCIALACCOUNT_PROVIDERS=%s\n' "$(
          ${pkgs.jq}/bin/jq -cn \
            --arg s "$secret" \
            --arg issuer "https://auth.${sp.domain}/oauth2/openid/${oauthClientID}" \
            '{"openid_connect":{"APPS":[{"provider_id":"kanidm","name":"Kanidm","client_id":"${oauthClientID}","secret":$s,"settings":{"server_url":$issuer}}]}}'
        )" > ${ssoEnvFile}
        chmod 600 ${ssoEnvFile}
      ''
    );

    services.paperless = {
      enable = true;
      dataDir = dataDir;
      address = "127.0.0.1";
      inherit port;
      settings = {
        PAPERLESS_URL = "https://${cfg.subdomain}.${sp.domain}";
        PAPERLESS_OCR_LANGUAGE = cfg.ocr-languages;
      } // lib.optionalAttrs hasAuth {
        PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
        PAPERLESS_REDIRECT_LOGIN_TO_SSO = "true";
        PAPERLESS_DISABLE_REGULAR_LOGIN = "true";
      };
    };

    systemd.services.paperless-web = lib.mkIf hasAuth {
      serviceConfig.EnvironmentFiles = [ "-${ssoEnvFile}" ];
    };

    services.nginx = {
      enable = true;
      virtualHosts."${cfg.subdomain}.${sp.domain}" = {
        useACMEHost = sp.domain;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString port}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_redirect http:// https://;
            proxy_buffering off;
            client_max_body_size 0;
          '';
        };
      };
    };

    selfprivacy.auth.clients = lib.mkIf hasAuth {
      ${oauthClientID} = {
        inherit adminsGroup usersGroup;
        imageFile = ./icon.svg;
        displayName = "Paperless-ngx";
        subdomain = cfg.subdomain;
        isTokenNeeded = false;
        originUrl = "https://${cfg.subdomain}.${sp.domain}/accounts/oidc/kanidm/login/callback/";
        originLanding = "https://${cfg.subdomain}.${sp.domain}";
        enablePkce = true;
        linuxUserOfClient = "paperless";
        linuxGroupOfClient = "paperless";
        clientSystemdUnits = [ "paperless-web.service" ];
      };
    };

    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}
