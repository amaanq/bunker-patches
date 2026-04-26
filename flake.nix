{
  description = "Bunker kernel";

  # Only used by `checks` below; the module itself stays consumer-driven
  # and pulls pkgs/lib from whichever nixpkgs the importer is using. Pinned
  # to a specific rev so VM test runs are reproducible without a tracked
  # flake.lock (.gitignore excludes it).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/0726a0ecb6d4e08f6adced58726b95db924cef57";

  outputs =
    { self, nixpkgs, ... }:
    {
      nixosModules.default = import ./module.nix self;

      checks.x86_64-linux.boot = nixpkgs.legacyPackages.x86_64-linux.testers.runNixOSTest {
        name = "bunkernel-boot";

        nodes.machine =
          { ... }:
          {
            imports = [ self.nixosModules.default ];
            bunker.kernel.enable = true;
          };

        testScript = ''
          machine.wait_for_unit("multi-user.target")
          kernel = machine.succeed("uname -r").strip()
          assert "bunker" in kernel, f"expected bunker kernel suffix, got {kernel!r}"
        '';
      };
    };
}
