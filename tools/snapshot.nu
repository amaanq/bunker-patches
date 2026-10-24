# Snapshots a host's bunker kernel for builders outside NixOS. The series lists
# lib.plan's patches in apply order, and the config is the .config nixpkgs'
# buildLinux resolves for that host.
#
#   nu tools/snapshot.nu derecho
#
# The flavor is a nixosConfigurations host in the dotfiles flake, evaluated with
# its tack bunker pin pointed at this tree.
def main [flavor: string, --dotfiles: path = ~/dotfiles] {
   let root = $env.FILE_PWD | path dirname
   let dots = mktemp --directory --tmpdir bunker-snapshot.XXXXXX

   ^rsync --archive --exclude .jj --exclude .git $"($dotfiles | path expand)/" $"($dots)/"

   let lock = $dots | path join .tack pins.lock.json
   open --raw $lock | from json | upsert bunker { type: path, path: $root } | to json --indent 2 | save --force $lock

   let host = $"path:($dots)#nixosConfigurations.($flavor).config"
   let options = ^nix eval --impure --json $"($host).bunker.kernel" | from json

   if not $options.enable { error make { msg: $"($flavor) does not enable bunker.kernel" } }

   let plan = $"\(import ($root)/plan.nix\).plan \(builtins.fromJSON ''($options | to json --raw)''\)"
   let patches = ^nix eval --impure --json --expr $"\(($plan)\).patches" | from json
   let config = ^nix build --impure --no-link --print-out-paths $"($host).boot.kernelPackages.kernel.configfile"

   mkdir ($root | path join series)
   $patches | str join "\n" | $in + "\n" | save --force ($root | path join series $flavor)
   open --raw $config | save --force ($root | path join kconfig $"($flavor).config")
   rm --recursive $dots | ignore
}
