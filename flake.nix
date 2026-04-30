{
  description = "Bunker kernel";

  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

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
