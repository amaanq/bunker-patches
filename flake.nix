{
  description = "Bunker kernel";
  outputs = { self, ... }: {
    nixosModules.default = import ./module.nix self;
  };
}
