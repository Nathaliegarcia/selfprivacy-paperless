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

  # Build OIDC provider JSON at runtime so the client secret is read from file
  ssoSetupScript = pkgs.writeShellScript "paperless-sso-setup" ''
    set -euo pipefail
    mkdir -p /run/paperless
    secret=$(cat ${lib.escapeShellArg (auth-passthru.mkOAuth2ClientSecretFP oauthClientID)})
    ${pkgs.jq}/bin/jq -cn \
      --arg secret "$secret" \
      --arg issuer "https://auth.${sp.domain}/oauth2/openid/${oauthClientID}" \
      --arg client_id "${oauthClientID}" \
      '{
        openid_connect: {
          APPS: [{
            provider_id: "authelia",
            name: "SelfPrivacy SSO",
            client_id: $client_id,
            secret: $secret,
            settings: { server_url: $issuer }
          }]
        }
      }' > /run/paperless/sso-env.json
    printf 'PAPERLESS_SOCIALACCOUNT_PROVIDERS=%s\n' \
      "$(cat /run/paperless/sso-env.json)" \
      > /run/paperless/sso-env
    chmod 600 /run/paperless/sso-env /run/paperless/sso-env.json
    chown paperless:paperless /run/paperless/sso-env /run/paperless/sso-env.json
  '';
in
{
  options.selfprivacy.modules.paperless = {
    enable = (lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Paperless-ngx";
    }) // {
      meta = {
        type = "enable";
      };
    };

    location = (lib.mkOption {
      type = lib.types.str;
      description = "Data location";
      default = "/volumes/${config.selfprivacy.useBinds.defaultVolume or "sda1"}/paperless";
    }) // {
      meta = {
        type = "location";
      };
    };

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
      type = lib.types.listOf lib.types.str;
      default = [ "eng" ];
      description = "OCR language packs to install (e.g. [\"eng\" \"fra\" \"deu\"])";
    }) // {
      meta = {
        type = "string";
        weight = 1;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = sp.domain != null && sp.domain != "";
        message = "selfprivacy.domain must be set for the Paperless module.";
      }
    ];

    fileSystems.${dataDir} = lib.mkIf (sp.useBinds or false) {
      device = cfg.location;
      fsType = "none";
      options = [ "bind" ];
    };

    services.paperless = {
      enable = true;
      dataDir = dataDir;
      address = "127.0.0.1";
      inherit port;
      extraConfig = {
        PAPERLESS_URL = "https://${cfg.subdomain}.${sp.domain}";
        PAPERLESS_OCR_LANGUAGE = lib.concatStringsSep "+" cfg.ocr-languages;
        PAPERLESS_ENABLE_HTTP_REMOTE_USER = false;
      } // lib.optionalAttrs hasAuth {
        PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
        PAPERLESS_REDIRECT_LOGIN_TO_SSO = "true";
        PAPERLESS_DISABLE_REGULAR_LOGIN = "true";
      };
    };

    # Oneshot service to build the SSO environment file from the OAuth2 secret
    systemd.services.paperless-sso-setup = lib.mkIf hasAuth {
      description = "Prepare Paperless-ngx SSO environment";
      before = [ "paperless-web.service" ];
      requiredBy = [ "paperless-web.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "paperless";
        RuntimeDirectoryMode = "0750";
        ExecStart = ssoSetupScript;
      };
    };

    # Inject the generated env file containing PAPERLESS_SOCIALACCOUNT_PROVIDERS
    systemd.services.paperless-web = lib.mkIf hasAuth {
      serviceConfig.EnvironmentFiles = [ "/run/paperless/sso-env" ];
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
        originUrl = "https://${cfg.subdomain}.${sp.domain}/accounts/oidc/authelia/login/callback/";
        originLanding = "https://${cfg.subdomain}.${sp.domain}";
        enablePkce = true;
        clientSystemdUnits = [ "paperless-web.service" ];
      };
    };

    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}
