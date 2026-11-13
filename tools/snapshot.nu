# Snapshots the .config nixpkgs' buildLinux resolves for a host, which
# compare.nu diffs a kernel built outside NixOS against.
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

   let config = ^nix build --impure --no-link --print-out-paths $"($host).boot.kernelPackages.kernel.configfile"

   open --raw $config | save --force ($root | path join kconfig $"($flavor).config")
   rm --recursive $dots | ignore
}
