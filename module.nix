flake:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mapAttrs
    mkEnableOption
    mkMerge
    mkOption
    mkIf
    mkForce
    optionalAttrs
    types
    ;
  inherit (lib.kernel)
    freeform
    module
    option
    yes
    no
    ;

  cfg = config.bunker.kernel;

  # Pin only the kernel build chain; module integration stays consumer-driven.
  # Forward both buildPlatform and hostPlatform so the pinned nixpkgs keeps
  # the consumer's cross context — passing `system` alone collapses to a
  # native pkgs and silently regresses the cross-compile fix. Also forward
  # the consumer's overlays so any bcachefs-tools / kernel-tooling patches
  # in the consumer's nixpkgs.overlays land here too.
  pkgsKernel = import flake.inputs.nixpkgs {
    localSystem = pkgs.stdenv.buildPlatform;
    crossSystem = pkgs.stdenv.hostPlatform;
    overlays = pkgs.overlays or [ ];
    inherit (pkgs) config;
  };

  isX86 = pkgsKernel.stdenv.hostPlatform.isx86_64;
  isAarch64 = pkgsKernel.stdenv.hostPlatform.isAarch64;
  isPpc64 = pkgsKernel.stdenv.hostPlatform.isPower64;
  isMips = pkgsKernel.stdenv.hostPlatform.isMips;

  planLib = import ./plan.nix;
  bunkerPlan = planLib.plan cfg;
  inherit (bunkerPlan) majorMinor kernelMajorMinor fullVersion;

  patchFile =
    p:
    builtins.path {
      path = p;
      name = builtins.unsafeDiscardStringContext (baseNameOf (toString p));
    };

  kernelPatches = map (rel: {
    name = baseNameOf rel;
    patch = patchFile "${flake}/patches/${rel}";
  }) bunkerPlan.patches;

  kernelLlvmPackages = pkgsKernel.pkgsBuildTarget.llvmPackages;

  # Keep hostPlatform as the kernel target; swap only build-native LLVM tools.
  llvmStdenv = pkgsKernel.overrideCC pkgsKernel.llvmPackages.stdenv (
    kernelLlvmPackages.clang.override {
      bintools = kernelLlvmPackages.bintools;
    }
  );

  kernelSrc =
    if bunkerPlan.source ? rev then
      pkgsKernel.fetchgit bunkerPlan.source
    else
      pkgsKernel.fetchurl bunkerPlan.source;

  isBigEndian = pkgsKernel.stdenv.hostPlatform.isBigEndian;

  # kconfig/<group>.toml holds SYMBOL = value, with subtables under a cpu or a
  # version key, the same files linux-bunker in repkgs reads. Every value is
  # forced so bunker wins over common-config, and optional because an `n` on a
  # symbol whose dependencies hide it is never asked, which generate-config.pl
  # would reject.
  cpuKeys = [
    "x86_64"
    "aarch64"
    "riscv64"
    "loongarch64"
    "powerpc64"
    "mips64"
  ];
  cpuKey =
    if isX86 then
      "x86_64"
    else if isAarch64 then
      "aarch64"
    else if isPpc64 then
      "powerpc64"
    else if isMips then
      "mips64"
    else
      null;
  # next keeps the Makefile version of the release it forked from, as the
  # version gates do with kernelMajorMinor
  admitted =
    clause:
    let
      parts = builtins.match "(>=|>|<=|<)?([0-9.]+)" clause;
      operator = builtins.elemAt parts 0;
      bound = builtins.elemAt parts 1;
    in
    if clause == "next" then
      cfg.version == "next"
    else if clause == "!next" then
      cfg.version != "next"
    else if parts == null then
      throw "bunker: ${clause} is neither a cpu nor a version range"
    else if operator == ">=" then
      lib.versionAtLeast kernelMajorMinor bound
    else if operator == ">" then
      lib.versionOlder bound kernelMajorMinor
    else if operator == "<=" then
      !(lib.versionOlder bound kernelMajorMinor)
    else if operator == "<" then
      lib.versionOlder kernelMajorMinor bound
    else
      kernelMajorMinor == bound || lib.hasPrefix "${bound}." kernelMajorMinor;
  applies =
    key: if lib.elem key cpuKeys then key == cpuKey else lib.all admitted (lib.splitString "," key);
  flatten = lib.concatMapAttrs (
    key: value:
    if builtins.isAttrs value then optionalAttrs (applies key) (flatten value) else { ${key} = value; }
  );
  answer =
    value:
    mkForce (
      option (
        if value == "y" then
          yes
        else if value == "n" then
          no
        else if value == "m" then
          module
        else
          freeform value
      )
    );
  # a symbol only version tables that do not apply name still answers, since
  # bunker names it to make common-config's request for it optional where this
  # kernel lacks it
  answered = lib.concatMapAttrs (
    key: value:
    if !builtins.isAttrs value then
      { ${key} = value; }
    else if lib.elem key cpuKeys then
      optionalAttrs (key == cpuKey) (answered value)
    else
      answered value
  );
  lacked = lib.concatMapAttrs (
    key: value:
    if !builtins.isAttrs value then
      { }
    else if lib.elem key cpuKeys || applies key then
      optionalAttrs (applies key) (lacked value)
    else
      answered value
  );
  group =
    name:
    let
      table = builtins.fromTOML (builtins.readFile ./kconfig/${name}.toml);
    in
    mapAttrs (_: answer) (lacked table // flatten table);

  baseConfig = group "base" // {
    RUST = mkForce (if cfg.rust then option yes else option no);
  };
  interactiveConfig = optionalAttrs cfg.interactive (group "interactive");
  hardenedConfig = optionalAttrs cfg.hardened (
    group "hardened" // optionalAttrs (!cfg.debugInfo) (group "hardened-no-debug-info")
  );
  trimmedConfig = optionalAttrs cfg.trimmed (
    group "trimmed"
    // optionalAttrs isX86 (lib.genAttrs cfg.devicetreeOnly (_: mkForce (option no)))
  );
  networkingConfig = optionalAttrs cfg.networking (group "networking");
  driversConfig = optionalAttrs cfg.drivers (group "drivers");
  openrgbSmbusConfig = optionalAttrs cfg.openrgbSmbus (group "openrgb-smbus");
  rustLtoConfig = optionalAttrs (cfg.rust && cfg.lto != "none") (group "rust-lto");
  debugInfoConfig = optionalAttrs (!cfg.debugInfo) (group "no-debug-info");
  ltoConfig = optionalAttrs (cfg.lto != "none") (group "lto-${cfg.lto}");
  cpuArchConfig = optionalAttrs (cfg.cpuArch != null) {
    ${cfg.cpuArch} = yes;
  };
  frameworkConfig = optionalAttrs cfg.framework (group "framework");
  bigEndianConfig = optionalAttrs isBigEndian (group "big-endian");
  octeonConfig = optionalAttrs cfg.octeon (group "octeon");

  bunkernel = pkgsKernel.linuxKernel.buildLinux (
    {
      pname = "linux-bunker";
      stdenv = llvmStdenv;
      src = kernelSrc;
      version = fullVersion;
      modDirVersion = "${fullVersion}-bunker";
      inherit kernelPatches;
      autoModules = !isMips;

      structuredExtraConfig =
        baseConfig
        // interactiveConfig
        // hardenedConfig
        // trimmedConfig
        // frameworkConfig
        // networkingConfig
        // driversConfig
        // openrgbSmbusConfig
        // rustLtoConfig
        // debugInfoConfig
        // ltoConfig
        // cpuArchConfig
        // bigEndianConfig
        // octeonConfig;

      extraMeta = {
        branch = majorMinor;
        description = "Bunker kernel";
      };
    }
    // optionalAttrs isMips { defconfig = "cavium_octeon_defconfig"; }
  );

  bunkernel' = bunkernel.overrideAttrs (old: {
    # The Clang+LTO+Rust kernel embeds build tool store paths (CC, LD,
    # RUSTC, KBUILD_OUTPUT, etc.) that Nix's reference scanner picks up as
    # runtime dependencies, dragging the entire toolchain into the closure.
    # - out: the kernel image (vmlinuz) itself has no runtime store deps
    # - dev: the kernel build directory embeds KBUILD_OUTPUT and toolchain
    #        paths needed to build out-of-tree modules; these are build-time
    #        only — no legitimate runtime store-path dependencies exist here
    # Requires __structuredAttrs = true (already set by nixpkgs' buildLinux).
    unsafeDiscardReferences = (old.unsafeDiscardReferences or { }) // {
      out = true;
      dev = true;
    };

    # Kernel BINDGEN step shells out to `rustfmt` to pretty-print the generated
    # bindings_generated.rs. Without it on PATH the build logs a warning per
    # file ("Failed to run rustfmt: No such file or directory") and emits the
    # raw bindgen output. Compiles fine either way; wire it up so the warnings
    # go away and the embedded source is human-readable when debugging.
    # ppc64 vDSO links via `clang -fuse-ld=lld`, which needs `ld.lld` on PATH.
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
      pkgsKernel.buildPackages.rustfmt
      kernelLlvmPackages.lld.out
    ];

    postInstall =
      builtins.replaceStrings
        [
          ''
            cp $buildRoot/{.config,Module.symvers} $dev/lib/modules/${bunkernel.modDirVersion}/build
            make modules_prepare "''${makeFlags[@]}" O=$dev/lib/modules/${bunkernel.modDirVersion}/build''
          "# Keep whole scripts dir"
        ]
        [
          ''
            devBuild=$dev/lib/modules/${bunkernel.modDirVersion}/build
            devSource=$dev/lib/modules/${bunkernel.modDirVersion}/source
            sourceRoot="$(dirname "$buildRoot")"

            # The build tree already has everything modules_prepare would rebuild.
            rsync --archive --prune-empty-dirs \
              --include='/.config' \
              --include='/Module.symvers' \
              --include='/Makefile' \
              --include='/.gitignore' \
              --include='/.missing-syscalls.d' \
              --include='/.*checked*' \
              --include='/arch/' \
              --include='/arch/*/' \
              --include='/arch/*/include/' \
              --include='/arch/*/include/generated/***' \
              --include='/arch/*/kernel/' \
              --include='/arch/*/kernel/*offsets.s' \
              --include='/arch/*/kernel/.*offsets.s.cmd' \
              --include='/arch/*/tools/***' \
              --include='/include/***' \
              --include='/kernel/' \
              --include='/kernel/*.s' \
              --include='/kernel/.*.cmd' \
              --include='/kernel/sched/' \
              --include='/kernel/sched/*.s' \
              --include='/kernel/sched/.*.cmd' \
              --include='/rust/***' \
              --include='/scripts/***' \
              --include='/tools/***' \
              --exclude='*' \
              "$buildRoot/" "$devBuild/"

            grep -IrlZ -e "$buildRoot" -e "$sourceRoot" "$devBuild" |
              while IFS= read -r -d "" metadata; do
                if grep -IqF "$buildRoot" "$metadata"; then
                  substituteInPlace "$metadata" --replace-fail "$buildRoot" "$devBuild"
                fi
                if grep -IqF "$sourceRoot" "$metadata"; then
                  substituteInPlace "$metadata" --replace-fail "$sourceRoot" "$devSource"
                fi
              done''
          ''
            # Keep rust Makefile and source files for rust-analyzer support
                      [ -f rust/Makefile ] && chmod u-w rust/Makefile
                      find rust -type f -name '*.rs' -print0 | xargs -0 -r chmod u-w

                      # Keep whole scripts dir''
        ]
        (old.postInstall or "");

    # Host GNU strip may not understand the target ELF in cross builds.
    preFixup = ''
      if [ -z "''${dontStrip-}" -a -e $out/vmlinux ]; then
        ${pkgsKernel.pkgsBuildBuild.llvmPackages.bintools-unwrapped}/bin/llvm-strip -S $out/vmlinux
      fi
    '';
  });

  # TILE-Gx bypasses the bunkernel machinery.
  tilegxKernelPackage = pkgs.linuxKernel.packagesFor pkgs.linux-tilegx;

  # Out-of-tree kernel modules embed KBUILD_OUTPUT (kernel.dev store path)
  # in DWARF debug info.  zstd may store these paths verbatim in literal
  # blocks.  NixOS's modules-closure.sh runs nuke-refs on the compressed
  # .ko.zst, byte-patching any /nix/store/ strings it finds — corrupting
  # the zstd frame checksum.  depmod then silently skips the module,
  # producing an empty modules.dep entry and a stage-2 boot failure.
  #
  # Fix: strip debug sections from .ko files after install (before zstd
  # compresses them), removing the embedded store paths at the source.
  # The kernel's own modules use the same compiler but are stripped by
  # the in-tree build system; out-of-tree modules skip that step.
  kernelPackage = (pkgsKernel.linuxKernel.packagesFor bunkernel').extend (
    _: prev:
    {
      kernelModuleMakeFlags = prev.kernelModuleMakeFlags ++ [ "INSTALL_MOD_STRIP=1" ];
    }
    // lib.optionalAttrs (prev ? bcachefs-tools) {
      # bch_bindgen sets `.layout_tests(true)`, which emits static assertions
      # like `align_of::<bch_replicas_padded__bindgen_ty_N>() - 4`. Cross-
      # compiling on x86_64 → aarch64, libclang reports packed-bitfield inner
      # types with align=1 against the aarch64 sysroot, but bindgen bakes in
      # an expected align of 4 — the assertion underflows at const-eval
      # (`1 - 4`). Native aarch64 builds don't hit this because libclang
      # picks the right alignment when host==target. Disable layout tests;
      # field offsets are still correct, only the debug-only static asserts
      # are dropped. Has to be a real `patches +=` — buildRustPackage's
      # cargoSetupPostPatchHook silently swallows overrideAttrs `postPatch`,
      # so substituteInPlace never runs.
      bcachefs-tools = prev.bcachefs-tools.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (patchFile ./patches/userspace/bcachefs-tools-disable-layout-tests.patch)
          # Diagnostic: WARN_ONCE on bch2_folio() being called without
          # PG_private set (folio->private aliases folio->swap), and on
          # bch2_set_folio_undirty() entered without the folio lock. The
          # crash signature was a fault dereferencing folio->private at a
          # kernel-virtual address with no direct-map backing; this patch
          # is here to localize the offending caller — remove once root
          # cause is identified.
          (patchFile ./patches/userspace/bcachefs-tools-diag-folio-uaf.patch)
        ];
        unsafeDiscardReferences = (old.unsafeDiscardReferences or { }) // {
          out = true;
        };
      });
    }
    # modules-closure.sh runs nuke-refs on compressed .ko.zst to strip
    # Nix store paths.  When zstd literal blocks contain kernel.dev
    # paths, nuke-refs corrupts the zstd frame checksum.  depmod
    # silently skips the file → empty modules.dep → stage-2 boot
    # failure.  Decompress, strip debug sections + nuke refs, then
    # recompress — keeps checksums intact for depmod/modprobe.
    // lib.optionalAttrs (prev ? zenpower) {
      zenpower = prev.zenpower.overrideAttrs (old: {
        makeFlags = prev.kernelModuleMakeFlags ++ (old.makeFlags or [ ]);
      });
    }
    // lib.optionalAttrs (prev ? bcachefs) {
      bcachefs =
        let
          bcachefs = prev.bcachefs.overrideAttrs (old: {
            patches =
              (old.patches or [ ])
              ++ [ (patchFile ./patches/userspace/bcachefs-btree-cache-dirty-throttle-half.patch) ]
              ++ lib.optional (cfg.version == "next") (
                patchFile ./patches/userspace/bcachefs-const-mnt-idmap.patch
              );
          });
        in
        pkgsKernel.runCommand "${bcachefs.name}-stripped"
          {
            nativeBuildInputs = [
              pkgsKernel.nukeReferences
              pkgsKernel.buildPackages.zstd
              pkgsKernel.stdenv.cc.bintools
            ];
            inherit (bcachefs) meta;
            # `strip` from a cross binutils wrapper is exposed as
            # `${targetPrefix}strip`, not bare `strip`. Plumb the prefix
            # through so the script works under both native and cross.
            targetPrefix = pkgsKernel.stdenv.cc.targetPrefix;
          }
          ''
            cp -r --no-preserve=mode ${bcachefs} $out
            find $out -name '*.ko.zst' | while read -r f; do
              zstd -d --rm "$f"
              ko="''${f%.zst}"
              "''${targetPrefix}strip" --strip-debug "$ko"
              nuke-refs "$ko"
              zstd --rm -q "$ko"
            done
          '';
    }
  );
in
{
  options.bunker.kernel = {
    enable = mkEnableOption "Bunker kernel";

    version = mkOption {
      type = types.enum [
        "6.19"
        "7.0"
        "7.1"
        "7.2"
        "7.3"
        "next"
      ];
      default = planLib.defaults.version;
      description = "Linux kernel major.minor version, or \"next\" for linux-next. Resolves to the pinned point release, rc or next tag.";
    };

    interactive = mkOption {
      type = types.bool;
      default = planLib.defaults.interactive;
      description = "Enable interactive/desktop performance patches (preempt, BFQ, RCU tuning, etc.).";
    };

    hardened = mkOption {
      type = types.bool;
      default = planLib.defaults.hardened;
      description = "Enable linux-hardened security patches (CFI, RANDSTRUCT, slab hardening, etc.).";
    };

    trimmed = mkOption {
      type = types.bool;
      default = true;
      description = "Disable dead/legacy modules and subsystems (old hardware, dead protocols, unused filesystems, etc.).";
    };

    devicetreeOnly = mkOption {
      type = types.listOf types.str;
      # Generated by kconfig/x86-devicetree-only.nu
      default = (import ./kconfig/x86-devicetree-only.nix).${cfg.version} or [ ];
      defaultText = lib.literalExpression "kconfig/x86-devicetree-only.nix for the version";
      description = "Modules turned off on x86 under `trimmed` because they only bind through Devicetree.";
    };

    networking = mkOption {
      type = types.bool;
      default = planLib.defaults.networking;
      description = "Enable networking patches (BBRv3, FQ-Codel).";
    };

    drivers = mkOption {
      type = types.bool;
      default = planLib.defaults.drivers;
      description = "Enable driver patches (ACS override, AMDGPU, HDMI, Bluetooth quirks, etc.).";
    };

    extras = mkOption {
      type = types.bool;
      default = planLib.defaults.extras;
      description = "Enable extra patches (sched_ext, v4l2loopback, Clang Polly, micro-arch targets, etc.).";
    };

    octeon = mkOption {
      type = types.bool;
      default = planLib.defaults.octeon;
      description = ''
        Cavium Octeon III support. This adds the PKO3 and BGX octeon3-ethernet
        driver, the cvmx SDK headers and executive, and the AR8033 RJ45 PHY.
      '';
    };

    tilegx = mkOption {
      type = types.bool;
      default = false;
      description = "Tilera TILE-Gx support.";
    };

    framework = mkOption {
      type = types.bool;
      default = false;
      description = "Enable CrOS EC base drivers for Framework laptops (used by framework-laptop-kmod).";
    };

    openrgbSmbus = mkOption {
      type = types.bool;
      default = planLib.defaults.openrgbSmbus;
      description = ''
        Enable the i2c-nct6775 SMBus adapter (bunker/0009), used by OpenRGB on
        Asus/MSI gaming motherboards with NCT6791/2/3/5/6/8 super-I/O chips.

        Off by default. This is a niche out-of-tree SMBus driver that bangs
        super-I/O ports directly to drive motherboard RGB lighting; opt in
        only on systems that actually run OpenRGB. Setting this option also
        selects I2C_NCT6775=m, so the i2c-nct6775 module gets built.
      '';
    };

    signedModules = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Pass `module.sig_enforce=1` so the kernel refuses unsigned modules at load time.

        Off by default because nixpkgs' linux-kernel build autogenerates an ephemeral
        signing key per build — in-tree modules are signed automatically, but any
        out-of-tree module the operator adds later (NVIDIA, ZFS, framework-laptop-kmod,
        VirtualBox, etc.) is rejected unless it was built against the same key. Combined
        with `bunker.kernel.lockdown != "none"`, the enforcement cannot be turned off
        at runtime: misconfiguration boots into a system without storage/network/GPU
        modules and is recoverable only by booting another kernel.

        Enable only after either: (a) confirming the consumer flake has
        `boot.extraModulePackages = [ ]`, or (b) pinning `MODULE_SIG_KEY` to a
        non-ephemeral PEM and signing every out-of-tree module against it. Manual
        `modprobe` from `boot.kernelModules` or service-side loaders is not covered
        by the warning.
      '';
    };

    lockdown = mkOption {
      type = types.enum [
        "none"
        "integrity"
        "confidentiality"
      ];
      default = "none";
      description = ''
        Set the kernel lockdown mode via `lockdown=<mode>` boot param. `none` (default)
        leaves lockdown disabled; `integrity` blocks operations that could let userspace
        modify the running kernel (kexec into unsigned image, writing /dev/mem,
        loading unsigned modules); `confidentiality` adds blocking of operations that
        could exfiltrate kernel memory (reading /dev/mem, /dev/kmem, MSRs, kprobes).

        Lockdown cannot be turned off at runtime once set. Verify your workflow
        (debuggers, perf, eBPF, kexec-based bootloaders) tolerates the chosen mode
        before enabling.
      '';
    };

    cpuArch = mkOption {
      type = types.nullOr (
        types.enum [
          "GENERIC_CPU"
          "X86_NATIVE_CPU"
          # AMD
          "MK8"
          "MK8SSE3"
          "MK10"
          "MBARCELONA"
          "MBOBCAT"
          "MJAGUAR"
          "MBULLDOZER"
          "MPILEDRIVER"
          "MSTEAMROLLER"
          "MEXCAVATOR"
          "MZEN"
          "MZEN2"
          "MZEN3"
          "MZEN4"
          "MZEN5"
          # Intel
          "MPSC"
          "MCORE2"
          "MNEHALEM"
          "MWESTMERE"
          "MSILVERMONT"
          "MGOLDMONT"
          "MGOLDMONTPLUS"
          "MSANDYBRIDGE"
          "MIVYBRIDGE"
          "MHASWELL"
          "MBROADWELL"
          "MSKYLAKE"
          "MSKYLAKEX"
          "MCANNONLAKE"
          "MICELAKE_CLIENT"
          "MICELAKE_SERVER"
          "MCOOPERLAKE"
          "MCASCADELAKE"
          "MTIGERLAKE"
          "MSAPPHIRERAPIDS"
          "MROCKETLAKE"
          "MALDERLAKE"
          "MRAPTORLAKE"
          "MMETEORLAKE"
          "MEMERALDRAPIDS"
        ]
      );
      default = null;
      description = "CPU micro-architecture Kconfig target. Requires extras group.";
      example = "MZEN5";
    };

    lto = mkOption {
      type = types.enum [
        "full"
        "thin"
        "none"
      ];
      default = "thin";
      description = "LTO mode for Clang.";
    };

    rust = mkOption {
      type = types.bool;
      default = planLib.defaults.rust;
      description = "Enable Rust support in the kernel.";
    };

    debugInfo = mkOption {
      type = types.bool;
      default = planLib.defaults.debugInfo;
      description = ''
        Build with DWARF debug info and BTF. This is off by default because
        the build strips vmlinux and the modules anyway, so outside of BTF the
        DWARF only slows the build down. Enable it for BPF LSM, fentry and
        CO-RE tooling, which under `hardened` also keeps the function tracer
        and the BPF JIT.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.cpuArch == null || cfg.extras;
          message = "bunker.kernel.cpuArch requires extras group (patch 0046 adds micro-arch targets).";
        }
      ];

      warnings = lib.optional (cfg.signedModules && config.boot.extraModulePackages != [ ]) ''
        bunker.kernel.signedModules is enabled and config.boot.extraModulePackages is non-empty.
        Out-of-tree modules built against the kernel's ephemeral signing key will load,
        but modules built separately (or against a different kernel build) will be rejected
        at runtime. Confirm every entry in extraModulePackages is built from this kernel's
        package set, or pin MODULE_SIG_KEY to a non-ephemeral PEM and sign manually.
      '';

      boot.kernelPackages = if cfg.tilegx then tilegxKernelPackage else kernelPackage;

      # NixOS's bcachefs module creates its own module instance via
      # callPackage, bypassing our kernel packages overlay.  Point it
      # at the stripped version explicitly.
      boot.bcachefs.modulePackage = config.boot.kernelPackages.bcachefs;
    }

    (mkIf cfg.hardened {
      boot.kernel.sysctl = {
        # Disable Magic SysRq key — potential security concern.
        "kernel.sysrq" = 0;
        # Hide kptrs even for processes with CAP_SYSLOG.
        "kernel.kptr_restrict" = 2;
        # Disable bpf() JIT (eliminates spray attacks). fentry trampolines and
        # bpf_loop callbacks refuse to load without it.
        "net.core.bpf_jit_enable" = cfg.debugInfo;
        # Disable ftrace debugging. 7.3 deprecated the knob and rejects 0 with EOPNOTSUPP.
        "kernel.ftrace_enabled" =
          if cfg.debugInfo || !lib.versionOlder kernelMajorMinor "7.3" then null else false;
        # Restrict dmesg to root (CONFIG_SECURITY_DMESG_RESTRICT equivalent).
        "kernel.dmesg_restrict" = 1;
        # Prevent unintentional fifo writes.
        "fs.protected_fifos" = 2;
        # Prevent unintended writes to already-created files.
        "fs.protected_regular" = 2;
        # Disable SUID binary dump.
        "fs.suid_dumpable" = 0;
        # Disallow profiling without CAP_SYS_ADMIN.
        "kernel.perf_event_paranoid" = 3;
        # Require CAP_BPF to use bpf.
        "kernel.unprivileged_bpf_disabled" = 1;

        # --- Network hardening ---
        # SYN flood protection.
        "net.ipv4.tcp_syncookies" = 1;
        # TIME-WAIT assassination protection (RFC 1337).
        "net.ipv4.tcp_rfc1337" = 1;
        # Reverse path filtering — drop spoofed-source packets.
        "net.ipv4.conf.all.rp_filter" = 1;
        "net.ipv4.conf.default.rp_filter" = 1;
        # Disable ICMP redirects — prevents MITM via fake route injection.
        "net.ipv4.conf.all.accept_redirects" = 0;
        "net.ipv4.conf.default.accept_redirects" = 0;
        "net.ipv6.conf.all.accept_redirects" = 0;
        "net.ipv6.conf.default.accept_redirects" = 0;
        "net.ipv4.conf.all.send_redirects" = 0;
        "net.ipv4.conf.default.send_redirects" = 0;
        # Disable source routing.
        "net.ipv4.conf.all.accept_source_route" = 0;
        "net.ipv6.conf.all.accept_source_route" = 0;
        # Log martian packets.
        "net.ipv4.conf.all.log_martians" = 1;
        "net.ipv4.conf.default.log_martians" = 1;
      };

      boot.kernelParams = [
        "page_alloc.shuffle=1"
        "sysrq_always_enabled=0"
        "kcore=off"
      ];
    })

    (mkIf cfg.signedModules {
      boot.kernelParams = [ "module.sig_enforce=1" ];
    })

    (mkIf (cfg.lockdown != "none") {
      boot.kernelParams = [ "lockdown=${cfg.lockdown}" ];
    })

    (mkIf cfg.interactive {
      boot.kernelParams = [
        "fbcon=nodefer"
      ];
    })
  ]);
}
