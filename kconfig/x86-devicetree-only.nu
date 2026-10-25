# x86 firmware describes hardware through ACPI and never hands Linux a
# Devicetree, so an I2C, SPI or platform driver whose only match table is
# of_device_id can't bind there. A driver stays if it also has an ACPI table,
# a legacy .detect probe, a driver for another bus, registers its own device,
# or has an id that other x86 code creates devices for by name, like
# x86-android-tablets and ipu-bridge do.
#
#   nu kconfig/x86-devicetree-only.nu derecho > kconfig/x86-devicetree-only.nix
#
# Per supported version it resolves the host's config with the list empty and
# prints the modular symbols that are Devicetree-only in that patched tree,
# leaving out what the config asks for, the same rule linux-bunker's build
# applies in repkgs. The host is a nixosConfigurations entry in the dotfiles
# flake, evaluated with its tack bunker pin pointed at this tree.

const named_buses = [i2c spi platform]

const enumerating_buses = [
   pci usb hid sdio serio acpi pnp virtio auxiliary hda
   snd_soc_acpi_mach serdev_device mdio ishtp_cl i3c
]

const device_registrations = [
   'i2c_new_(client|scanned|ancillary)_device'
   i2c_acpi_new_device
   spi_new_device
   'platform_device_(register|alloc|add_data)\w*'
   platform_create_bundle
]

const device_creators = [
   ...$device_registrations
   board_info
   '\.(type|modalias)\s*=\s*"'
   platform_device_info
   mfd_cell
   'MFD_CELL_\w+'
]

def main [flavor: string, --dotfiles: path = ~/dotfiles] {
   let root = $env.FILE_PWD | path dirname
   let dots = mktemp --directory --tmpdir bunker-devicetree.XXXXXX

   ^rsync --archive --exclude .jj --exclude .git $"($dotfiles | path expand)/" $"($dots)/"

   let lock = $dots | path join .tack pins.lock.json
   open --raw $lock | from json | upsert bunker { type: path, path: $root } | to json --indent 2 | save --force $lock

   let versions = ^nix eval --impure --json --expr $"builtins.attrNames \(import ($root)/plan.nix\).release" | from json
   let lists = $versions | each {|version|
      let host = $"\(\(builtins.getFlake \"path:($dots)\"\).nixosConfigurations.($flavor).extendModules { modules = [ \({ lib, ... }: { bunker.kernel.version = lib.mkForce \"($version)\"; bunker.kernel.devicetreeOnly = [ ]; }\) ]; }\)"
      let kernel = $"($host).config.boot.kernelPackages.kernel"
      let config = ^nix build --impure --no-link --print-out-paths --expr $"($kernel).configfile"
      let tree = ^nix build --impure --no-link --print-out-paths --expr $"($host).pkgs.applyPatches { name = \"bunker-tree\"; inherit \(($kernel)\) src patches; }"
      let requested = ^nix eval --impure --json --expr $"builtins.attrNames ($kernel).configfile.structuredConfig" | from json
      { version: $version, symbols: (cull $tree $config $requested) }
   }
   rm --recursive $dots | ignore

   $lists
   | each {|list| [$'  "($list.version)" = [' ...($list.symbols | each {|sym| $'    "($sym)"' }) '  ];'] }
   | flatten
   | prepend '{'
   | append '}'
   | str join "\n"
}

# Modular symbols in one tree whose drivers are all Devicetree-only.
def cull [tree: path, config: path, requested: list<string>]: nothing -> list<string> {
   let modular = open --raw $config | lines | parse -r '^CONFIG_(?<sym>\w+)=m$' | get sym | where $it not-in $requested | to-set
   let named = instantiated-names $tree
   let selected = selected-symbols $tree

   let rules = makefiles $tree | each {|mk|
      let dir = $mk | path dirname
      let text = open --raw $mk | str replace -ra '\\\n' ' '
      {
         objs: ($text | kbuild $dir 'obj-\$\(CONFIG_(?<key>\w+)\)')
         parts: ($text | kbuild $dir '(?<key>[\w-]+)-(?:y|objs|\$\(CONFIG_\w+\))')
      }
   }
   let parts = $rules.parts | flatten | update key {|r| $r.obj | path dirname | path join $'($r.key).o' } | group-by key

   $rules.objs
   | flatten
   | where {|r| $r.key in $modular and $r.key not-in $selected }
   | group-by key
   | transpose sym rows
   | par-each {|g| if ($g.rows.obj | sources $parts | devicetree-only $named) { $g.sym } }
   | compact
   | sort
}

# Kbuild makefiles outside other architectures, tools and docs.
def makefiles [tree: path]: nothing -> list<path> {
   let skip = [arch tools Documentation samples] | each {|d| [-path ($tree | path join $d) -prune -o] } | flatten
   ^find $tree ...$skip -type f -name Makefile -print
   | lines
   | append (^find ($tree | path join arch/x86) -type f -name Makefile | lines)
}

# One row per object on each Kbuild assignment matching lhs.
def kbuild [dir: path, lhs: string]: string -> table {
   parse -r ('(?m)^' + $lhs + '\s*[+:]?=\s*(?<list>.*)$')
   | each {|r| $r.list | split row -r '\s+' | where $it ends-with '.o' | each {|o| {key: $r.key, obj: ($dir | path join $o)} } }
   | flatten
}

# Files that mention each string literal, among files that create I2C, SPI or
# platform devices by name.
def instantiated-names [tree: path]: nothing -> record {
   let roots = [drivers sound lib net arch/x86] | each {|d| $tree | path join $d }
   ^grep -rlE --include=*.c --include=*.h (alt ...$device_creators) ...$roots
   | lines
   | ^grep -oHE '"[A-Za-z0-9_,.+-]+"' ...$in
   | lines
   | parse -r '^(?<file>[^:]+):"(?<name>[^"]+)"$'
   | group-by name
   | items {|name, rows| [$name ($rows.file | uniq)] }
   | into record
}

# Symbols something selects, since generate-config.pl loops on a forced "no" there.
def selected-symbols [tree: path]: nothing -> record {
   ^grep -rhoE --include=Kconfig* '^\s+select\s+\w+' $tree
   | lines
   | each { str trim | split row -r '\s+' | last }
   | to-set
}

# C sources behind a module's objects, through composite objects.
def sources [parts: record]: list<path> -> list<path> {
   each {|o| $parts | get -o $o | default [{obj: $o}] | get obj }
   | flatten
   | each { str replace -r '\.o$' '.c' }
   | where { path exists }
}

# True when the sources can only bind through Devicetree on x86.
def devicetree-only [named: record]: list<path> -> bool {
   let sources = $in
   if ($sources | is-empty) { return false }

   let text = $sources | each { open --raw } | str join "\n"
   if ($text | binds-elsewhere) { return false }
   $text | id-names | all {|n| $named | get -o $n | default [] | all { $in in $sources } }
}

# True when the driver has a way to bind that x86 can reach.
def binds-elsewhere []: string -> bool {
   let text = $in
   (
      not    ($text | matches (driver-for $named_buses))
      or     ($text | matches (driver-for $enumerating_buses))
      or not ($text | matches 'struct of_device_id\b')
      or     ($text | matches 'struct acpi_device_id\b' acpi_match_table)
      or     ($text | matches '\.detect\s*=')
      or     ($text | matches ...$device_registrations)
   )
}

# Regex for a driver struct, id table or module helper of any of these buses.
def driver-for [buses: list<string>]: nothing -> string {
   let bus = alt ...$buses
   alt ('struct ' + $bus + '_(device_id|driver)\b') ('module_' + $bus + '_driver\(')
}

# True when the input matches any of the patterns.
def matches [...patterns: string]: string -> bool {
   $in =~ (alt ...$patterns)
}

# Joins patterns into one regex alternation.
def alt [...patterns: string]: nothing -> string {
   '(' + ($patterns | str join '|') + ')'
}

# Names in the id tables and the driver's own .name, with macro names resolved.
def id-names []: string -> list<string> {
   let text = $in
   let defines = $text | parse -r '#define\s+(?<macro>\w+)\s+"(?<name>[^"]+)"'
   $text
   | parse -r ('(?s)' + (alt ...$named_buses) + '_device_id\s+\w+\[\]\s*=\s*\{(?<body>.*?)\n\};')
   | get body
   | append ($text | parse -r '\.driver\s*=\s*\{[^}]*?\.name\s*=\s*(?<body>"[^"]+"|[A-Z][A-Z0-9_]+)' | get body)
   | each {|body|
      let macros = $body | parse -r '\b(?<m>[A-Z][A-Z0-9_]+)\b' | get m
      $body | parse -r '"(?<n>[\w,.+-]+)"' | get n | append ($defines | where macro in $macros | get name)
   }
   | flatten
}

# Record keyed by each string, for constant time membership tests.
def to-set []: list<string> -> record {
   uniq | each {|n| [$n true] } | into record
}
