{
  description = "Bunker kernel";

  # Checks are pinned; consumers still provide nixpkgs to the module.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/b12141ef619e0a9c1c84dc8c684040326f27cdcc";

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
