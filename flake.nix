{
  description = "SelfPrivacy module for Paperless-ngx";

  outputs = { self }: {
    nixosModules.default = import ./module.nix;

    configPathsNeeded =
      builtins.fromJSON (builtins.readFile ./config-paths-needed.json);

    meta = { lib, ... }: {
      spModuleSchemaVersion = 1;
      id = "paperless";
      name = "Paperless-ngx";
      description = "Document management system that transforms physical documents into a searchable online archive";
      svgIcon = builtins.readFile ./icon.svg;

      showUrl = true;
      primarySubdomain = "subdomain";

      isMovable = true;
      isRequired = false;
      canBeBackedUp = true;
      backupDescription = "Paperless documents, database, and configuration.";

      systemdServices = [
        "paperless-web.service"
        "paperless-scheduler.service"
        "paperless-task-queue.service"
        "paperless-consumer.service"
      ];
      user = "paperless";
      group = "paperless";

      folders = [
        "/var/lib/paperless"
      ];

      homepage = "https://docs.paperless-ngx.com";
      sourcePage = "https://github.com/paperless-ngx/paperless-ngx";
      supportLevel = "normal";
      license = [ lib.licenses.gpl3Only ];
    };
  };
}
