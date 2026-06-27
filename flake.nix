{
  description = "Bunker kernel";

  outputs =
    { self, ... }@args:
    let
      inputs = (import ./.tack) { overrides = args.tackOverrides or { }; };
      inherit (inputs) nixpkgs;
      flake = self // {
        inputs = { inherit nixpkgs; };
      };
    in
    {
      nixosModules.default = import ./module.nix flake;

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
