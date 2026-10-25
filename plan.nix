let
  inherit (builtins)
    attrNames
    compareVersions
    concatMap
    concatStringsSep
    elemAt
    filter
    genList
    isString
    length
    listToAttrs
    match
    readDir
    split
    splitVersion
    stringLength
    substring
    ;

  defaults = {
    version = "7.2";
    interactive = true;
    hardened = true;
    networking = true;
    drivers = true;
    extras = true;
    octeon = false;
    openrgbSmbus = false;
    rust = true;
    debugInfo = false;
  };

  release = {
    "6.19" = "6.19.12";
    "7.0" = "7.0.13";
    "7.1" = "7.1.5";
    "7.2" = "7.2.8";
    "7.3" = "7.3";
    next = "7.3-next-20261022";
  };

  sourceHash = {
    "6.19.12" = "sha256-zlxPEgX5cpKGtWmwN2SVkVVfMcoeA8xQS9O3C45YqNU=";
    "7.0.13" = "sha256-PIHt0PcWrKPdSN/2kWgYJ1gMxT01qO7DvkfTRtH4mRM=";
    "7.1.5" = "sha256-IqAZazy83zTcJ7d1YfTQQFhf00R+3JqzUxoax54wQec=";
    "7.2.8" = "sha256-EujVqXPRrXxaXGmILkAisTHtcV23AD/c12Dd+MPlGUE=";
    "7.3" = "sha256-hzY8JPEOBjIes2J2VSEJTpRHH2v/i84taz5A858ASVM=";
    "7.3-next-20261022" = "sha256-VAmgNjyRNGx2LQPsIQNbU804F1u5R2MyfFMbgDsRRfs=";
  };

  optional = cond: x: if cond then [ x ] else [ ];
  versionAtLeast = v: floor: compareVersions v floor != -1;
  versionPart = v: n: elemAt (splitVersion v) n;
  pad4 = n: substring 0 (4 - stringLength (toString n)) "0000" + toString n;
  numbered = subdir: count: genList (i: "${subdir}/${pad4 (i + 1)}") count;

  plan =
    options:
    let
      cfg = defaults // options;
      majorMinor = cfg.version;

      resolvedVersion =
        release.${majorMinor} or (throw "bunker: unsupported kernel version ${majorMinor}");

      # "next" sorts below every number in compareVersions, so version gates use
      # the release the tree is based on.
      kernelMajorMinor = "${versionPart resolvedVersion 0}.${versionPart resolvedVersion 1}";

      fullVersion =
        let
          parts = match "([0-9.]+)(.*)" resolvedVersion;
          base = elemAt parts 0;
        in
        (if length (filter isString (split "\\." base)) >= 3 then base else "${base}.0") + elemAt parts 1;

      # cgit drops the connection generating linux-next snapshot tarballs, so
      # next is cloned instead.
      source =
        if majorMinor == "next" then
          {
            url = "https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git";
            rev = "refs/tags/next-${elemAt (match ".*-next-(.*)" resolvedVersion) 0}";
            hash = sourceHash.${resolvedVersion};
          }
        else if match ".*-rc.*" resolvedVersion != null then
          {
            url = "https://git.kernel.org/torvalds/t/linux-${resolvedVersion}.tar.gz";
            hash = sourceHash.${resolvedVersion};
          }
        else
          {
            url = "https://cdn.kernel.org/pub/linux/kernel/v${versionPart resolvedVersion 0}.x/linux-${resolvedVersion}.tar.xz";
            hash = sourceHash.${resolvedVersion};
          };

      # Shared keys are stable; upstream/ numbering is version-specific.
      sharedGroups = {
        base = [
          "bunker/0001"
          "bunker/0016"
        ];
        interactive = [
          # zen: mm tuning, preempt, BFQ/Kyber, EEVDF, swap/watermark/compaction
          "zen/0009"
          "zen/0010"
          "zen/0012"
          "zen/0013"
          "zen/0014"
          "zen/0015"
          "zen/0016"
          "zen/0017"
          "zen/0018"
          "zen/0019"
          # cachyos: inline sched/mm/tick/vtime fixes, ADIOS, le9, compaction, BFQ lock, POCC
          "cachyos/0002" # fixes: __always_inline sched/mm/tick/vtime, RCU QS, NUMA, quirks
          "cachyos/0006"
          "bunker/0014" # ADIOS: per-queue slab cache names, plus clzll(0) guard pre-7.2 (must follow cachyos/0006)
          "cachyos/0007"
          "cachyos/0009"
          "cachyos/0010"
          "cachyos/0012"
          "cachyos/0013"
          "cachyos/0019"
          # xanmod: sched latency, yield, block/mq-deadline, vfs, rwsem, accept LIFO, dm-crypt
          "xanmod/0001"
          "xanmod/0002"
          "xanmod/0003"
          "xanmod/0004"
          "xanmod/0005"
          "xanmod/0006"
          "xanmod/0007"
          "xanmod/0014"
          # clear: sched/fair cpu, timer slack, memcg, compaction, branch hints
          "clear/0005"
          "clear/0006"
          "clear/0007"
          "clear/0008"
          "clear/0009"
          "clear/0010"
          # bunker: VM_READAHEAD_PAGES, exit mm teardown on the unbound workqueue
          "bunker/0005"
          "bunker/0022"
        ];
        hardened =
          # 7.1 onward tracks anthraxx's official 101-patch series and picks
          # up three extra GrapheneOS patches.
          numbered "hardened"
            {
              "6.19" = 101;
              "7.0" = 105;
              "7.1" = 101;
              "7.2" = 100;
              "7.3" = 101;
              next = 101;
            }
            .${majorMinor}
          ++ numbered "grapheneos" (if versionAtLeast kernelMajorMinor "7.1" then 8 else 5)
          ++ [
            "bunker/0003" # rust: allow clang native randstruct
            "bunker/0004" # enable RANDSTRUCT_FULL by default
            "bunker/0006" # enable KSTACK_ERASE by default
            "bunker/0007" # enable PAGE_TABLE_CHECK_ENFORCED by default
            "bunker/0008" # disable PROC_KCORE by default
          ];
        networking = [
          "cachyos/0001" # BBRv3
          "xanmod/0012" # tcp: skip collapse sysctl
          "clear/0001"
          "clear/0002"
          "clear/0003"
          "clear/0004"
        ];
        drivers = [
          "zen/0001"
          "zen/0002"
          "bunker/0015" # NVMe remap: NULL-check devm_kzalloc (must follow zen/0002)
          "zen/0004"
          "zen/0005"
          "zen/0006"
          "zen/0007"
          "zen/0008"
          "zen/0011"
          "cachyos/0003"
          "cachyos/0015"
          "cachyos/0018"
          "bunker/0013" # r8125: disable vendor /proc debug files (must follow cachyos/0018)
          "bunker/0002"
          "bunker/0010" # rust: backlight device abstraction
          "clear/0011" # PCI PME interval
        ];
        rustBtf = [
          "bunker/0021" # rust: allow BTF with LTO
        ];
        openrgbSmbus = [
          "bunker/0009" # i2c-nct6775: OpenRGB SMBus for gaming motherboard RGB
        ];
        extras = [
          "cachyos/0004"
          "cachyos/0008"
          "cachyos/0011"
          "cachyos/0016"
          "cachyos/0017"
          "xanmod/0008"
          "xanmod/0009"
        ];
        # Cavium Octeon III ethernet patches for mips64.
        octeon = numbered "octeon" 14;
      };

      # Per-version upstream/ entries + any version-specific group overrides.
      # upstream/ numbering differs because each release has different backport sets.
      versionGroups = {
        "6.19" = {
          interactive = [
            "zen/0003"
            "upstream/0002"
            "upstream/0003"
            "upstream/0004"
            "upstream/0005"
            "upstream/0006"
            "upstream/0010"
            "upstream/0011"
            "upstream/0024"
            "upstream/0025"
            "upstream/0026"
            "upstream/0027"
            "upstream/0028"
            "upstream/0029"
            "upstream/0030"
            "upstream/0031"
            "upstream/0032"
            "upstream/0033"
            "upstream/0034"
            "upstream/0035"
            "upstream/0036"
            "upstream/0037"
            # Limit accept-LIFO to pre-7.1 kernels because it can stall rtw89
            # association (CachyOS/linux-cachyos#921).
            "xanmod/0013"
            "bunker/0012"
          ];
          hardened = [
            "upstream/0022"
            "upstream/0023"
            "cachyos/0014" # VMSCAPE/BHB clear mitigation
            "bunker/0011" # VMSCAPE: barrier_nospec after static call (must follow cachyos/0014)
          ];
          networking = [
            "upstream/0007"
            "upstream/0008"
            "upstream/0009"
            "upstream/0012"
            "upstream/0013"
            "upstream/0014"
            "upstream/0015"
            "upstream/0016"
            "upstream/0017"
            "upstream/0018"
            "upstream/0019"
          ];
          drivers = [ "cachyos/0005" ]; # Zen errata workaround, folded into cachyos/0002 on 7.2
          extras = [
            "xanmod/0010"
            "xanmod/0011" # C binder, deleted in linux-next
            "upstream/0020"
            "upstream/0021"
            "xanmod/0015"
          ];
        };
        "7.0" = {
          # POC 2.6.3 filters candidates by p->cpus_ptr, so 7.1 no longer needs
          # bunker/0012's affinity-gate fix for POC 1.6.
          interactive = [
            "zen/0020"
            "xanmod/0013"
            "bunker/0012"
          ];
          hardened = [
            "cachyos/0014" # VMSCAPE/BHB clear mitigation
            "bunker/0011" # VMSCAPE: barrier_nospec after static call (must follow cachyos/0014)
          ];
          drivers = [ "cachyos/0005" ]; # Zen errata workaround, folded into cachyos/0002 on 7.2
          extras = [
            "xanmod/0010"
            "xanmod/0011" # C binder, deleted in linux-next
          ];
        };
        "7.1" = {
          interactive = [
            "zen/0020"
            "bunker/0017" # is_idle_core stub arity (must follow cachyos/0012)
          ];
          hardened = [
            "cachyos/0014" # VMSCAPE/BHB clear mitigation
            "bunker/0011" # VMSCAPE: barrier_nospec after static call (must follow cachyos/0014)
          ];
          drivers = [ "cachyos/0005" ]; # Zen errata workaround, folded into cachyos/0002 on 7.2
          extras = [
            "xanmod/0010"
            "xanmod/0011" # C binder, deleted in linux-next
            "cachyos/0020"
          ];
        };
        # mainline 7.2 absorbed the carries the older releases still need
        "7.2" = {
          base = [ "bunker/0018" ]; # reclaim-safe vmap purge
          interactive = [ "zen/0020" ];
          extras = [
            "xanmod/0010"
            "xanmod/0011" # C binder, deleted in linux-next
            "cachyos/0020"
          ];
        };
        "7.3" = {
          base = [ "bunker/0018" ]; # reclaim-safe vmap purge
          interactive = [ "zen/0020" ];
          extras = [
            "xanmod/0010"
            "xanmod/0011" # C binder, deleted in linux-next
            "cachyos/0020"
          ];
        };
        next = {
          base = [ "bunker/0023" ]; # libbpf use-after-free in resolve_btfids --inline
          interactive = [ "zen/0020" ];
          extras = [ "cachyos/0020" ];
        };
      };

      vg = versionGroups.${majorMinor};

      enabledGroups = [
        "base"
      ]
      ++ optional cfg.interactive "interactive"
      ++ optional cfg.hardened "hardened"
      ++ optional cfg.networking "networking"
      ++ optional cfg.drivers "drivers"
      ++ optional cfg.extras "extras"
      ++ optional cfg.openrgbSmbus "openrgbSmbus"
      ++ optional cfg.octeon "octeon"
      ++ optional (cfg.rust && cfg.debugInfo) "rustBtf";

      enabledKeys = concatMap (g: sharedGroups.${g} ++ (vg.${g} or [ ])) enabledGroups;

      # Patch keys are "subdir/NNNN", derived from the filename prefix.
      collectPatches =
        rel: subdir:
        let
          entries = readDir (./patches + "/${rel}");
          names = type: filter (n: entries.${n} == type) (attrNames entries);
          patches = filter (n: match ".*\\.patch" n != null) (names "regular");
          prefix = n: substring 0 4 n;
        in
        map (n: {
          name = if subdir == "" then prefix n else "${subdir}/${prefix n}";
          value = "${rel}/${n}";
        }) patches
        ++ concatMap (d: collectPatches "${rel}/${d}" d) (names "directory");

      patchByKey = listToAttrs (collectPatches majorMinor "");

      # Listed group order is authoritative; missing keys fail loud.
      missingKeys = filter (k: !(patchByKey ? ${k})) enabledKeys;
    in
    {
      inherit
        majorMinor
        kernelMajorMinor
        fullVersion
        source
        ;
      version = resolvedVersion;
      patches =
        if missingKeys != [ ] then
          throw "bunker: enabled patches missing from patches/${majorMinor}/: ${concatStringsSep ", " missingKeys}"
        else
          map (k: patchByKey.${k}) enabledKeys;
    };
in
{
  inherit defaults plan release;
}
