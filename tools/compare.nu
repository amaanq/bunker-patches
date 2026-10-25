# Diffs a .config built outside NixOS against a host's snapshot from snapshot.nu.
#
#   nu tools/compare.nu derecho /nix/store/...-linux-bunker-dev/lib/modules/*/build/.config
#
# Symbols the compiler decides, its version strings and the CC_HAS probes, are printed apart from
# the diff since a builder on another clang moves them without any request changing.
def main [flavor: string, built: path] {
   let root = $env.FILE_PWD | path dirname
   let toolchain = '(_VERSION|_VERSION_TEXT)$|^CC_HAS_|^CC_OPT_|^RUSTC_CLANG_LLVM_COMPATIBLE$|^KMALLOC_PARTITION_TYPED$|^DEBUG_INFO_COMPRESSED_ZSTD$'

   let parse = {|file|
      open --raw $file | lines | each {|line|
         if ($line | str starts-with "CONFIG_") {
            let pair = $line | str substring 7.. | split row --number 2 "="
            { symbol: $pair.0, value: $pair.1 }
         } else if ($line =~ '^# CONFIG_\S+ is not set$') {
            { symbol: ($line | parse '# CONFIG_{symbol} is not set' | get 0.symbol), value: "n" }
         }
      } | compact | transpose --as-record --header-row
   }

   let want = do $parse ($root | path join kconfig $"($flavor).config")
   let have = do $parse $built
   let symbols = $want | columns | append ($have | columns) | uniq

   let diff = $symbols | each {|symbol|
      let left = $want | get --optional $symbol | default "n"
      let right = $have | get --optional $symbol | default "n"
      if $left != $right { { symbol: $symbol, snapshot: $left, built: $right } }
   } | compact

   let compiler = $diff | where symbol =~ $toolchain
   let rest = $diff | where symbol !~ $toolchain

   if ($compiler | is-not-empty) { print $"($compiler | length) compiler-decided" ($compiler | table) }
   print $"($rest | length) differing"
   if ($rest | is-not-empty) { print ($rest | table); exit 1 }
}
