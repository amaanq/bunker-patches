flake:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatMap
    mapAttrs
    mkEnableOption
    mkMerge
    mkOption
    mkIf
    mkForce
    mkOverride
    optionalAttrs
    types
    ;
  inherit (lib.kernel)
    freeform
    option
    yes
    no
    ;

  cfg = config.bunker.kernel;
  forceAll = mapAttrs (_: mkForce);

  isX86 = pkgs.stdenv.hostPlatform.isx86_64;

  # Map user-facing major.minor → latest stable point release
  stableRelease = {
    "6.18" = "6.18.10";
    "6.19" = "6.19";
  };

  resolvedVersion =
    stableRelease.${cfg.version} or (throw "bunker: unsupported kernel version ${cfg.version}");

  # "6.18.10" → "6.18", "6.19" → "6.19"
  majorMinor = cfg.version;

  # "6.18" → "6.18.10", "6.19" → "6.19.0"
  fullVersion =
    let
      parts = lib.splitString "." resolvedVersion;
    in
    if builtins.length parts >= 3 then resolvedVersion else "${resolvedVersion}.0";

  # Patch group → 4-digit prefix strings
  patchGroups = {
    base = [ "0015" ];
    interactive = [
      "0003"
      "0011"
      "0012"
      "0014"
      "0016"
      "0017"
      "0018"
      "0019"
      "0020"
      "0021"
      "0022"
      "0023"
      "0024"
      "0025"
      "0028"
      "0029"
      "0030"
      "0031"
      "0032"
      "0033"
      "0039"
      "0040"
      "0043"
      "0044"
      "0045"
      "0051"
      "0053"
      "0054"
      "0055"
      "0171"
      "0172"
      "0173"
      "0174"
      "0175"
      "0176"
      "0177"
      "0178"
      "0185"
      "0186"
      "0187"
      "0188"
      "0189"
      "0190"
      "0194"
      "0195"
      "0212"
      "0213"
      "0214"
      "0215"
      "0216"
      "0217"
      "0218"
      "0219"
      "0220"
      "0221"
      "0222"
      "0223"
      "0224"
      "0225"
    ];
    hardened = [
      "0006"
      "0007"
      "0056"
    ]
    ++ (lib.genList (
      i:
      let
        n = i + 60;
      in
      lib.fixedWidthString 4 "0" (toString n)
    ) 107)
    # 0060..0166
    ++ [
      "0182"
      "0183"
      "0184"
      "0210"
      "0211"
    ];
    networking = [
      "0027"
      "0052"
      "0167"
      "0168"
      "0169"
      "0170"
      "0191"
      "0192"
      "0193"
      "0196"
      "0197"
      "0198"
      "0199"
      "0200"
      "0201"
      "0202"
      "0203"
    ];
    drivers = [
      "0001"
      "0002"
      "0004"
      "0005"
      "0008"
      "0009"
      "0010"
      "0013"
      "0026"
      "0034"
      "0036"
      "0037"
      "0038"
      "0042"
      "0057"
      "0179"
      "0180"
    ];
    extras = [
      "0035"
      "0041"
      "0046"
      "0047"
      "0048"
      "0049"
      "0050"
      "0058"
      "0059"
      "0208"
      "0209"
    ];
  };

  # Per-version extra patches (upstreamed or version-specific).
  # 6.19-only patches (0186-0190 TEO, 0198 fq-tweak) are in shared groups
  # and naturally skipped in 6.18 where the files don't exist.
  versionExtra = {
    "6.18" = {
      drivers = [
        "0204"
        "0206"
      ];
      extras = [ "0205" ];
    };
  };

  extra = versionExtra.${majorMinor} or { };

  enabledGroups = [
    "base"
  ]
  ++ lib.optional cfg.interactive "interactive"
  ++ lib.optional cfg.hardened "hardened"
  ++ lib.optional cfg.networking "networking"
  ++ lib.optional cfg.drivers "drivers"
  ++ lib.optional cfg.extras "extras";

  enabledNumbers = concatMap (g: patchGroups.${g} ++ (extra.${g} or [ ])) enabledGroups;
  enabledSet = lib.genAttrs enabledNumbers (_: true);

  # All patch files from the patches directory, sorted numerically
  patchDir = "${flake}/patches/${majorMinor}";
  allPatchFiles =
    builtins.filter (n: lib.hasSuffix ".patch" n) (builtins.attrNames (builtins.readDir patchDir))
    |> builtins.sort builtins.lessThan;

  # Filter patches by prefix membership, preserving numeric order
  selectedPatches = builtins.filter (name: enabledSet ? ${builtins.substring 0 4 name}) allPatchFiles;

  kernelPatches = map (name: {
    inherit name;
    patch = "${patchDir}/${name}";
  }) selectedPatches;

  # Full LLVM stdenv with clang + lld + llvm-ar/nm (required for LTO_CLANG / CFI)
  llvmStdenv = pkgs.overrideCC pkgs.llvmPackages.stdenv (
    pkgs.llvmPackages.clang.override {
      bintools = pkgs.llvmPackages.bintools;
    }
  );

  sourceHash =
    {
      "6.18.10" = "sha256-1tN3FhdBraL6so7taRQyd2NKKuteOIPlDAMViO3kjt4=";
      "6.19" = "sha256-MDB5qCULjzgfgrA/kEY9EqyY1PaxSbdh6nWvEyNSE1c=";
    }
    .${resolvedVersion};

  kernelSrc = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v${
      builtins.substring 0 1 cfg.version
    }.x/linux-${resolvedVersion}.tar.xz";
    hash = sourceHash;
  };

  # Per-group structured kconfig.
  # Uses optionalAttrs (not mkIf) because these are merged with // into buildLinux,
  # which is outside the module system's merging.
  baseConfig = {
    BUNKER = yes;
    LOCALVERSION = freeform "-bunker";
    MODULE_DECOMPRESS = yes; # in-kernel module decompression
    FW_LOADER_COMPRESS_ZSTD = yes; # zstd firmware compression
  }
  // forceAll {
    MODULE_COMPRESS_ZSTD = yes;
    MODULE_COMPRESS_XZ = no;
  };

  interactiveConfig = optionalAttrs cfg.interactive (
    {
      HZ = freeform "1000";
      HZ_1000 = yes;
      MQ_IOSCHED_ADIOS = yes;
      FUTEX = yes;
      FUTEX_PI = yes;
      NTSYNC = yes;
      TREE_RCU = yes;
      PREEMPT_RCU = yes;
      RCU_EXPERT = yes;
      TREE_SRCU = yes;
      TASKS_RCU_GENERIC = yes;
      TASKS_RCU = yes;
      TASKS_RUDE_RCU = yes;
      TASKS_TRACE_RCU = yes;
      RCU_STALL_COMMON = yes;
      RCU_NEED_SEGCBLIST = yes;
      RCU_FANOUT = freeform "64";
      RCU_FANOUT_LEAF = freeform "16";
      RCU_BOOST = yes;
      RCU_BOOST_DELAY = option (freeform "500");
      RCU_NOCB_CPU = yes;
      RCU_LAZY = yes;
      RCU_DOUBLE_CHECK_CB_TIME = yes;
      LRU_GEN = yes; # Multi-gen LRU — better memory reclaim under pressure
      LRU_GEN_ENABLED = yes;
    }
    // optionalAttrs isX86 {
      X86_AMD_PSTATE = yes;
      X86_AMD_PSTATE_DEFAULT_MODE = freeform "3";
      X86_FRED = yes; # Flexible Return and Event Delivery (Zen 5+ / Arrow Lake+)
      PERF_EVENTS_AMD_POWER = yes; # AMD power events for perf profiling
    }
    // mapAttrs (_: mkOverride 90) {
      PREEMPT = yes;
      PREEMPT_VOLUNTARY = no;
      IOSCHED_BFQ = yes;
    }
    // forceAll {
      TRANSPARENT_HUGEPAGE_ALWAYS = yes;
      TRANSPARENT_HUGEPAGE_MADVISE = no;
      MQ_IOSCHED_KYBER = no;
      BLK_WBT = no;
      BLK_WBT_MQ = option no;
    }
  );

  hardenedConfig = optionalAttrs cfg.hardened (
    {
      # --- Security features ---
      CFI = yes;
      CFI_PERMISSIVE = no;
      ZERO_CALL_USED_REGS = yes;
      SECURITY_SAFESETID = yes;
      BUG_ON_DATA_CORRUPTION = yes; # panic on slab/list corruption
      SECURITY_DMESG_RESTRICT = yes; # restrict dmesg before sysctl runs

      # --- ASLR maximization ---
      ARCH_MMAP_RND_BITS = freeform "32"; # max ASLR entropy for mmap (default 28)
      ARCH_MMAP_RND_COMPAT_BITS = freeform "16"; # max ASLR for 32-bit compat
      RANDOMIZE_KSTACK_OFFSET_DEFAULT = yes; # randomize kernel stack per syscall

      # --- Integrity & verified boot ---
      TRUSTED_KEYS = yes; # TPM-sealed keys
      ENCRYPTED_KEYS = yes; # kernel-managed encrypted keys (dm-crypt, IMA)
      FS_VERITY = yes; # file-level Merkle tree integrity
      FS_VERITY_BUILTIN_SIGNATURES = yes; # verify fs-verity against built-in X.509
      DM_VERITY_VERIFY_ROOTHASH_SIG = yes; # signature check on dm-verity root hash
      FS_ENCRYPTION_INLINE_CRYPT = yes; # hardware crypto offload for fscrypt
    }
    // forceAll {
      # --- Disabled features — attack surface reduction, debug infra, etc. ---
      STRICT_DEVMEM = option no;
      IO_STRICT_DEVMEM = option no;

      # Attack surface reduction (KSPP)
      USELIB = option no; # a.out uselib() syscall
      SYSFS_SYSCALL = option no; # old sysfs() syscall
      KEXEC = option no; # bypasses secure boot chain
      KEXEC_JUMP = option no; # kexec hibernation variant
      BOOT_CONFIG = option no; # extra kernel params via initrd bootconfig
      X86_IOPL_IOPERM = option no; # IOPL/IOPERM syscalls
      X86_VSYSCALL_EMULATION = option no; # legacy vsyscall page
      X86_X32_ABI = option no; # x32 ABI (exotic, deprecated)
      X86_SGX = option no; # Intel SGX enclaves
      DEVPORT = option no; # /dev/port I/O port access

      # Unused security modules
      SECURITY_SELINUX = option no; # SELinux (~20k LOC, NixOS uses AppArmor)
      SECURITY_TOMOYO = option no; # TOMOYO (~10k LOC, unused on NixOS)

      # Obsolete crypto
      CRYPTO_USER_API_ENABLE_OBSOLETE = option no; # Gates ANUBIS/KHAZAD/SEED/TEA
      CRYPTO_FCRYPT = option no; # fcrypt (only for dead AFS/RxRPC)

      # Debug/testing infrastructure
      KCOV = option no; # Syzkaller fuzzing infra
      GCOV_KERNEL = option no; # Kernel code coverage
      FAULT_INJECTION = option no; # Debug fault injection framework
      KASAN = option no; # Kernel Address Sanitizer
      KMEMLEAK = option no; # Kernel memory leak detector
      PROVE_LOCKING = option no; # Lock dependency validator (lockdep)
      LOCK_STAT = option no; # Lock contention statistics
      NOTIFIER_ERROR_INJECTION = option no; # Error injection for notifier chains
      DEBUG_PAGEALLOC = option no; # Debug page allocation
      KUNIT = option no; # Kernel unit testing framework
      EXT4_DEBUG = option no; # ext4 debug
      JBD2_DEBUG = option no; # ext4 journaling debug
      SLUB_DEBUG = option no; # SLUB allocator debug
      DYNAMIC_DEBUG = option no; # Runtime pr_debug control
      FUNCTION_TRACER = option no; # ftrace (stronger than sysctl disable)
      FUNCTION_GRAPH_TRACER = option no; # ftrace graph tracer
      PM_DEBUG = option no; # Power management debug
      PM_ADVANCED_DEBUG = option no; # Advanced PM debug
      PM_SLEEP_DEBUG = option no; # PM sleep debug
      ACPI_DEBUG = option no; # ACPI debug
      SCHED_DEBUG = option no; # Scheduler debug
      LATENCYTOP = option no; # Latency measurement infrastructure
      DEBUG_PREEMPT = option no; # Preemption debug
      DEBUG_MISC = option no; # Miscellaneous debug
      GENERIC_IRQ_DEBUGFS = option no; # IRQ debug filesystem
      X86_MCE_INJECT = option no; # MCE injection for testing
      HIBERNATION = option no; # writes unencrypted memory to disk

      # Child options of disabled security parents
      X86_SGX_KVM = option no;
    }
  );

  trimmedConfig = optionalAttrs cfg.trimmed (forceAll {
    # --- Dead network hardware ---
    ARCNET = option no; # 1970s token-passing network
    FDDI = option no; # 1980s fiber ring
    HIPPI = option no; # 1990s supercomputer interconnect
    PLIP = option no; # Parallel Line IP
    EQUALIZER = option no; # Serial/PLIP link load balancer

    # --- Dead network protocols ---
    ATALK = option no; # Appletalk
    ATM = option no; # Async Transfer Mode
    AX25 = option no; # Amateur radio X.25
    CAN = option no; # Controller Area Network
    DECNET = option no; # DECnet
    HAMRADIO = option no; # Amateur radio umbrella (ax25/netrom/rose)
    IEEE802154 = option no; # Wireless sensor networks
    IP_DCCP = option no; # Datagram Congestion Control
    IP_SCTP = option no; # Stream Control Transmission
    IPX = option no; # Internetwork Packet Exchange
    NETROM = option no; # Amateur radio NetRom
    N_HDLC = option no; # HDLC line discipline
    ROSE = option no; # Amateur radio ROSE
    RDS = option no; # Reliable Datagram Sockets
    TIPC = option no; # Transparent IPC
    X25 = option no; # X.25 packet switching
    AF_RXRPC = option no; # RxRPC sessions (only for AFS)
    AF_KCM = option no; # Kernel Connection Multiplexor
    PHONET = option no; # Nokia Phonet
    CAIF = option no; # ST-Ericsson modem IPC
    "6LOWPAN" = option no; # IPv6 over low-power networks
    NFC = option no; # Near Field Communication
    WIMAX = option no; # WiMAX (dead standard)
    MCTP = option no; # Management Component Transport
    HSR = option no; # High-availability Seamless Redundancy
    OPENVSWITCH = option no; # Open vSwitch (selects MPLS)
    MPLS = option no;
    BATMAN_ADV = option no; # B.A.T.M.A.N. mesh
    NET_DSA = option no; # Distributed Switch Architecture

    # --- Server/cloud networking ---
    GENEVE = option no; # Cloud overlay
    NET_TEAM = option no; # Network teaming
    MACSEC = option no; # 802.1AE MAC encryption
    NET_SWITCHDEV = option no; # Switch offload

    # --- Dead/unused filesystems ---
    ADFS_FS = option no;
    AFFS_FS = option no;
    AFS_FS = option no; # Andrew File System
    BEFS_FS = option no;
    BFS_FS = option no;
    CEPH_FS = option no;
    CIFS = option no; # NixOS might enable
    CRAMFS = option no;
    EFS_FS = option no;
    EROFS_FS = option no;
    F2FS_FS = option no;
    GFS2_FS = option no;
    HFS_FS = option no;
    HFSPLUS_FS = option no;
    HPFS_FS = option no;
    JFFS2_FS = option no;
    JFS_FS = option no;
    MINIX_FS = option no;
    NILFS2_FS = option no;
    OCFS2_FS = option no;
    OMFS_FS = option no;
    ORANGEFS_FS = option no;
    QNX4FS_FS = option no;
    QNX6FS_FS = option no;
    REISERFS_FS = option no;
    SMB_SERVER = option no; # ksmbd
    SQUASHFS = option no; # NixOS might enable
    SYSV_FS = option no;
    UDF_FS = option no;
    VXFS_FS = option no; # freevxfs
    ZONEFS_FS = option no;
    CODA_FS = option no; # Coda distributed filesystem
    ROMFS_FS = option no; # ROM filesystem (embedded)
    UBIFS_FS = option no; # UBI flash filesystem (embedded)
    NTFS_FS = option no; # Old NTFS driver (NTFS3 supersedes)
    MSDOS_FS = option no; # 8.3 FAT (VFAT supersedes)

    # --- Dead subsystems ---
    FIREWIRE = option no; # IEEE 1394
    PROVIDE_OHCI1394_DMA_INIT = option no; # FireWire remote debug on boot
    INFINIBAND = option no; # RDMA/InfiniBand
    ISDN = option no; # ISDN telephony
    PCMCIA = option no; # CardBus
    PARPORT = option no; # Parallel port
    INPUT_JOYSTICK = no; # Disables all gameport joystick drivers (bool, not tristate)
    GAMEPORT = option no; # Legacy gameport (freed by INPUT_JOYSTICK=n)
    COMEDI = option no; # Data acquisition
    GREYBUS = option no; # Project Ara
    STAGING = option no; # Experimental drivers

    # --- Dead buses/subsystems (industrial/embedded/ARM) ---
    VME_BUS = option no; # VMEbus (1980s industrial crate bus)
    RAPIDIO = option no; # Telecom/DSP interconnect
    IPACK = option no; # IndustryPack automation
    SIOX = option no; # Eckelmann industrial protocol
    HSI = option no; # Nokia modem serial (one dead chipset)
    MOST = option no; # Automotive infotainment bus
    SPMI = option no; # Qualcomm ARM power management bus
    SLIMBUS = option no; # Qualcomm ARM audio codec bus
    INTERCONNECT = option no; # ARM SoC interconnect framework
    BATTERY_DS2780 = option no; # niche battery chip (selects W1)
    BATTERY_DS2781 = option no; # niche battery chip (selects W1)
    W1 = option no; # 1-Wire bus
    NTB = option no; # Non-Transparent Bridge (multi-host PCIe)
    COUNTER = option no; # Embedded quadrature encoders
    GNSS = option no; # GPS/GNSS receivers over serial
    MELLANOX_PLATFORM = option no; # Mellanox switch ASICs (not ConnectX NICs)
    PCCARD = option no; # 16-bit PC Card (dead since ~2005)
    AGP = option no; # Accelerated Graphics Port (all GPUs use PCIe)
    EISA = option no; # Extended ISA bus (dead since ~2000)
    I3C = option no; # MIPI I3C bus (embedded/phone only)
    MTD = option no; # Memory Technology Devices (raw flash, embedded)
    YENTA = no; # Yenta PCMCIA - Old laptop bus

    # --- Dead memory technologies ---
    X86_PMEM_LEGACY = option no; # non-standard NVDIMMs (selects LIBNVDIMM)
    ACPI_NFIT = option no; # NVDIMM firmware table (selects LIBNVDIMM)
    LIBNVDIMM = option no; # persistent memory
    DEV_DAX = option no; # DAX devices for persistent memory
    CXL_BUS = option no; # Compute Express Link (bleeding-edge server)

    # --- Dead GPU drivers ---
    DRM_SIS = option no; # SiS GPUs (dead vendor ~2008)
    DRM_VIA = option no; # VIA GPUs (dead GPU division)
    DRM_SAVAGE = option no; # S3 Savage GPUs (dead ~2003)
    DRM_NOUVEAU = option no; # NVIDIA open-source (use proprietary or AMD)
    DRM_RADEON = option no; # Pre-GCN AMD GPUs (pre-2012, use AMDGPU)

    # --- Dead misc hardware ---
    MEMSTICK = option no; # Sony Memory Stick (dead format)
    PHONE = option no; # ISA/PCI telephony cards
    AUXDISPLAY = option no; # Character LCD displays (parallel port)
    ACRN_GUEST = option no; # ACRN hypervisor guest (dead hypervisor)
    RAW_DRIVER = option no; # /dev/raw (deprecated, use O_DIRECT)
    INTEL_IOATDMA = option no; # old Xeon DMA engine (selects DCA)
    DCA = option no; # Direct Cache Access
    HANGCHECK_TIMER = option no; # Server cluster heartbeat
    HOTPLUG_PCI_CPCI = option no; # CompactPCI hotplug (industrial)
    BLK_DEV_DRBD = option no; # DRBD distributed block replication
    MOUSE_SERIAL = option no; # Serial mice (RS-232)
    SERIO_SERPORT = option no; # Serial port input devices
    # Modules that `select SERIO_SERPORT` — must also be disabled to avoid
    # a kconfig select conflict (repeated-question failure on aarch64).
    I2C_TAOS_EVM = option no;
    USB_EXTRON_DA_HD_4K_PLUS_CEC = option no;
    USB_PULSE8_CEC = option no;
    USB_RAINSHADOW_CEC = option no;
    SND_ISA = option no; # ISA sound cards
    # Legacy PCI sound cards (select SND_OPL3_LIB / SND_MPU401_UART)
    SND_ALS300 = option no;
    SND_ALS4000 = option no;
    SND_ALI5451 = option no;
    SND_AU8810 = option no;
    SND_AU8820 = option no;
    SND_AU8830 = option no;
    SND_AZT3328 = option no;
    SND_CMIPCI = option no;
    SND_OXYGEN = option no;
    SND_CS4281 = option no;
    SND_ES1938 = option no;
    SND_ES1968 = option no;
    SND_FM801 = option no;
    SND_ICE1712 = option no;
    SND_RIPTIDE = option no;
    SND_SE6X = option no;
    SND_SONICVIBES = option no;
    SND_TRIDENT = option no;
    SND_VIA82XX = option no;
    SND_VIRTUOSO = option no;
    SND_YMFPCI = option no;
    SND_MPU401 = option no; # standalone MPU-401 driver
    SND_OPL3_LIB = option no;
    SND_OPL4_LIB = option no;
    SND_MPU401_UART = option no;
    SND_SB_COMMON = option no; # SoundBlaster common (ISA-era)
    SND_OSSEMUL = option no; # OSS API emulation (deprecated ~20yr)
    SND_PCM_OSS = option no; # OSS /dev/dsp emulation
    SND_MIXER_OSS = option no; # OSS /dev/mixer emulation
    SND_SEQUENCER_OSS = option no; # OSS sequencer emulation
    SND_SERIAL_U16550 = option no; # UART16550 serial MIDI

    # --- Dead input devices ---
    JOYSTICK_ANALOG = option no; # Analog gameport joystick
    MOUSE_ATIXL = option no; # ATI XL bus mouse
    MOUSE_INPORT = option no; # Microsoft InPort bus mouse
    MOUSE_LOGIBM = option no; # Logitech bus mouse
    KEYBOARD_LKKBD = option no; # DEC LK201/LK401 (serial)
    KEYBOARD_NEWTON = option no; # Apple Newton keyboard
    KEYBOARD_SUNKBD = option no; # Sun keyboard (serial)
    KEYBOARD_STOWAWAY = option no; # Stowaway portable keyboard

    # --- Dead platform drivers ---
    SONYPI = option no; # Old Sony VAIO programmable I/O
    ACPI_CMPC = option no; # Classmate PC (dead OLPC-like)
    COMPAL_LAPTOP = option no; # Compal IFL90/JFL92 laptops
    AMILO_RFKILL = option no; # Fujitsu Amilo RF kill
    TOSHIBA_HAPS = option no; # Toshiba HDD Active Protection (SSD era)

    # --- Dead block/storage hardware ---
    BLK_DEV_FD = option no; # Floppy disk
    PATA_LEGACY = option no; # ISA-era parallel ATA
    PATA_ISAPNP = option no; # ISA PnP parallel ATA
    BLK_DEV_DAC960 = option no; # Mylex DAC960 RAID (dead vendor)
    BLK_DEV_UMEM = option no; # Micro Memory MM5415 RAM card
    BLK_DEV_NULL_BLK = option no; # Null block device (testing only)
    CRYPTO_842 = option no; # 842 compression algorithm (rarely used)

    # --- Dead cpufreq drivers ---
    X86_SPEEDSTEP_CENTRINO = option no; # Pentium M/Centrino
    X86_SPEEDSTEP_ICH = option no; # Old ICH chipsets
    X86_SPEEDSTEP_SMI = option no; # SMI-based (ancient laptops)
    X86_SPEEDSTEP_LIB = option no; # SpeedStep common code
    X86_P4_CLOCKMOD = option no; # Pentium 4 clock modulation
    X86_POWERNOW_K6 = option no; # AMD K6
    X86_POWERNOW_K7 = option no; # AMD K7 (Athlon)
    X86_POWERNOW_K8 = option no; # AMD K8 (Athlon 64)
    X86_GX_SUSPMOD = option no; # Cyrix/NatSemi Geode GX
    X86_LONGHAUL = option no; # VIA C3
    X86_E_POWERSAVER = option no; # VIA C7
    X86_LONGRUN = option no; # Transmeta (bankrupt)

    # --- Dead misc drivers ---
    APPLICOM = option no; # Industrial fieldbus cards
    PHANTOM = option no; # SensAble PHANToM haptic device
    MMC_TIFM_SD = option no; # TI flash media SD (selects TIFM_CORE)
    MEMSTICK_TIFM_MS = option no; # TI flash media MemoryStick (selects TIFM_CORE)
    TIFM_CORE = option no;
    TELCLOCK = option no; # Telecom clock (MCPL0010)
    ECHO = option no; # Telephony echo cancellation
    RPMSG = option no; # Remote Processor Messaging (ARM)
    REMOTEPROC = option no; # Remote Processor framework (ARM)

    # --- Dead media ---
    MEDIA_ANALOG_TV_SUPPORT = option no; # Analog TV (shut off globally)
    MEDIA_DIGITAL_TV_SUPPORT = option no; # DVB digital TV tuners
    DVB_CORE = option no; # Digital Video Broadcasting
    MEDIA_SDR_SUPPORT = option no; # Software defined radio

    # --- Dead network transports ---
    SLIP = option no; # Serial Line IP (dialup)
    ATA_OVER_ETH = option no; # ATA over Ethernet
    LAPB = option no; # X.25 link layer
    PKTGEN = option no; # Kernel packet generator (testing)
    N_GSM = option no; # GSM 0710 mux for old serial modems
    BT_CMTP = option no; # Bluetooth CAPI (ISDN over BT)

    # --- Server block/storage ---
    BLK_DEV_NBD = option no; # Network block device
    BLK_DEV_RBD = option no; # Ceph/RADOS block
    TARGET_CORE = option no; # SCSI target
    ISCSI_TCP = option no; # iSCSI initiator
    NVME_TARGET = option no; # NVMe-oF target

    # --- Unused large subsystems ---
    IP_VS = option no; # IPVS load balancer (~30k LOC, only k8s IPVS mode)
    NFSD = option no; # NFS server (~25k LOC, client kept via NFS_FS)
    QUOTA = option no; # Disk quotas (~10k LOC, multi-user server feature)

    # --- Legacy/deprecated hardware & interfaces ---
    PCSPKR_PLATFORM = option no; # PC speaker
    CDROM_PKTCDVD = option no; # Packet writing to CD/DVDs
    EFI_VARS = option no; # Old sysfs EFI vars (EFIVAR_FS supersedes)
    RAID_AUTODETECT = option no; # Legacy MD RAID autodetect
    FB_DEVICE = option no; # Legacy /dev/fb* (DRM/KMS supersedes)
    FRAMEBUFFER_CONSOLE_LEGACY_ACCELERATION = option no; # Legacy fbcon hw accel
    X86_MPPARSE = option no; # MPS tables (pre-ACPI SMP)
    X86_EXTENDED_PLATFORM = option no; # Non-standard x86 platforms (SGI UV, etc.)
    GART_IOMMU = option no; # AMD K8-era GART IOMMU (modern uses AMD-Vi)
    REROUTE_FOR_BROKEN_BOOT_IRQS = option no; # Workaround for ancient BIOS IRQ routing
    MSDOS_PARTITION = option no; # MBR partition table (GPT era)
    ACCESSIBILITY = option no; # Speakup screen reader

    # --- Unused platform drivers ---
    CHROME_PLATFORMS = option no; # ChromeOS platform drivers
    MACINTOSH_DRIVERS = option no; # Apple hardware drivers
    APPLE_PROPERTIES = option no; # Apple device properties
    XEN = option no; # Xen hypervisor (we use KVM)
    SURFACE_PLATFORMS = option no; # Microsoft Surface

    # Obsolete Network (10/100 NICs from 1990s/2000s)
    ADAPTEC_STARFIRE = no; # Adaptec Starfire Ethernet - Old PCI NIC (1990s)
    DE2104X = no; # DEC 21x4x Tulip Ethernet - Ancient PCI NIC
    TULIP = no; # DEC Tulip Ethernet - Legacy 1990s NIC
    WINBOND_840 = no; # Winbond W89c840 Ethernet - Obsolete 10/100 NIC
    DM9102 = no; # Davicom DM9102 Ethernet - Old PCI NIC
    ULI526X = no; # ULi M526x Ethernet - Legacy 10/100 NIC
    HAMACHI = no; # Packet Engines Hamachi - Old Gigabit NIC
    YELLOWFIN = no; # Packet Engines Yellowfin - Old Gigabit NIC
    NATSEMI = no; # National Semiconductor DP8381x - Legacy 10/100 NIC
    NS83820 = no; # National Semiconductor DP83820 - Old Gigabit NIC
    S2IO = no; # Neterion S2IO 10GbE - Deprecated server NIC
    NE2K_PCI = no; # NE2000 PCI Ethernet - Ancient 10Mbps NIC
    FORCEDETH = no; # NVIDIA nForce Ethernet - Legacy chipset NIC
    ETHOC = no; # OpenCores Ethernet - FPGA embedded NIC
    R6040 = no; # RDC R6040 Ethernet - Embedded/industrial NIC
    ATP = no; # Realtek RTL8012 ATP - Ancient 10Mbps ISA NIC

    # Additional Ancient SCSI (pre-2010)
    SCSI_3W_XXXX_RAID = no; # 3ware Escalade RAID - Ancient RAID (pre-2005)
    SCSI_3W_9XXX = no; # 3ware 9000 series RAID - Legacy RAID controller
    SCSI_3W_SAS = no; # 3ware SAS RAID - Obsolete SAS RAID
    SCSI_MVSAS = no; # Marvell SAS/SATA - Old enterprise SAS
    SCSI_MVUMI = no; # Marvell UMI - Legacy RAID
    SCSI_ADVANSYS = no; # AdvanSys SCSI - Ancient SCSI card
    SCSI_ARCMSR = no; # Areca RAID - Legacy RAID controller
    SCSI_ESAS2R = no; # ATTO ESAS RAID - Old RAID controller
    SCSI_HPTIOP = no; # HighPoint RocketRAID - Legacy RAID
    SCSI_BUSLOGIC = no; # BusLogic SCSI - 1990s SCSI controller
    SCSI_DMX3191D = no; # DMX3191D SCSI - Obsolete SCSI
    SCSI_FDOMAIN = no; # Future Domain SCSI - Ancient SCSI card
    SCSI_ISCI = no; # Intel C600 SAS - Old server chipset SAS
    SCSI_IPS = no; # IBM ServeRAID - Legacy IBM RAID
    SCSI_INITIO = no; # Initio SCSI - 1990s SCSI controller
    SCSI_INIA100 = no; # InitIO INI-A100U/W - Ancient SCSI
    SCSI_PPA = no; # Iomega PPA (parallel port) - Parallel port ZIP drive
    SCSI_IMM = no; # Iomega IMM (parallel port) - Parallel port ZIP drive
    SCSI_STEX = no; # Promise SuperTrak EX - Legacy RAID
    SCSI_SYM53C8XX_2 = no; # Symbios 53C8xx SCSI - 1990s SCSI controller
    SCSI_QLOGIC_1280 = no; # QLogic 1280 SCSI - Old SCSI controller
    SCSI_DC395x = no; # Tekram DC395x SCSI - 1990s SCSI card
    SCSI_AM53C974 = no; # AMD AM53C974 SCSI - Ancient SCSI
    SCSI_WD719X = no; # Western Digital WD719x - 1990s SCSI controller
    SCSI_PMCRAID = no; # PMC-Sierra RAID - Legacy RAID
    SCSI_PM8001 = no; # PMC-Sierra 8001 SAS - Old SAS controller

    # Legacy PATA/IDE Controllers (pre-SATA era)
    PATA_ALI = no; # ALI PATA - Legacy chipset IDE
    PATA_ARTOP = no; # ARTOP PATA - Old IDE controller
    PATA_ATIIXP = no; # ATI IXP PATA - Legacy IDE
    PATA_ATP867X = no; # ATP867X PATA - Obsolete IDE
    PATA_CMD64X = no; # CMD64x PATA - 1990s IDE controller
    PATA_CYPRESS = no; # Cypress PATA - Old IDE controller
    PATA_EFAR = no; # EFAR PATA - Legacy IDE
    PATA_HPT366 = no; # HPT366 PATA - Old IDE RAID
    PATA_HPT37X = no; # HPT37x PATA - Legacy IDE RAID
    PATA_HPT3X2N = no; # HPT3x2N PATA - Obsolete IDE RAID
    PATA_IT8213 = no; # IT8213 PATA - Old IDE controller
    PATA_IT821X = no; # IT821X PATA - Legacy IDE RAID
    PATA_NETCELL = no; # NetCell PATA - Obsolete IDE
    PATA_OLDPIIX = no; # Intel PIIX1/2 PATA - Ancient IDE (pre-2000)
    PATA_PDC2027X = no; # Promise PDC2027x - Legacy IDE RAID
    PATA_PDC_OLD = no; # Promise old PATA - Old IDE RAID
    PATA_RADISYS = no; # Radisys PATA - Obsolete IDE
    PATA_RDC = no; # RDC PATA - Legacy embedded IDE
    PATA_TOSHIBA = no; # Toshiba PATA - Old laptop IDE
    PATA_TRIFLEX = no; # Compaq Triflex PATA - Ancient IDE

    # Old Wireless (Pre-WiFi 6 - 802.11b/g/n legacy)
    ADM8211 = no; # ADMtek ADM8211 WLAN - 802.11b (1999)
    ATH5K = no; # Atheros AR5xxx - 802.11a/b/g (pre-2008)
    ATH9K = no; # Atheros AR9xxx - 802.11n (old gen)
    ATH9K_HTC = no; # Atheros AR9271 USB - Old 802.11n USB
    CARL9170 = no; # Atheros AR9170 USB - Legacy 802.11n
    ATH6KL = no; # Atheros AR600x - Old embedded WiFi
    AR5523 = no; # Atheros AR5523 - Legacy 802.11g USB
    IPW2100 = no; # Intel PRO/Wireless 2100 - 802.11b (2003)
    IPW2200 = no; # Intel PRO/Wireless 2200BG - 802.11b/g (2004)
    IWL3945 = no; # Intel Wireless 3945ABG - 802.11a/b/g (2006)
    IWL4965 = no; # Intel Wireless 4965AGN - 802.11n draft (2007)
    LIBERTAS = no; # Marvell Libertas - 802.11b/g (old)
    AT76C50X_USB = no; # Atmel AT76C50x - 802.11b USB
    B43 = no; # Broadcom b43 - Legacy BCM43xx
    B43LEGACY = no; # Broadcom b43legacy - Ancient BCM430x
    MWIFIEX = no; # Marvell mwifiex - Old embedded WiFi
    MWL8K = no; # Marvell 88W8xxx - Legacy PCI WiFi
    P54_COMMON = no; # Prism54 - 802.11g (2004)
    RT2X00 = no; # Ralink RT2x00 - Old 802.11n
    RT2500USB = no; # Ralink RT2500 USB - 802.11g (2004)
    RT73USB = no; # Ralink RT73 USB - 802.11g (2005)
    RTL8180 = no; # Realtek RTL8180 - 802.11b PCI
    RTL8187 = no; # Realtek RTL8187 - 802.11g USB
    RTL8192CU = no; # Realtek RTL8192CU - Old 802.11n USB

    # SoC-specific (ARM/MIPS only, not applicable to x86_64)
    QCA7000 = no; # Qualcomm QCA7000 - Embedded PLC (Power Line)
    QCOM_EMAC = no; # Qualcomm EMAC - ARM SoC Ethernet
    RMNET = no; # Qualcomm RMNET - Mobile modem interface
    SPI_FSL_LIB = no; # Freescale SPI - ARM SoC SPI
    SPI_FSL_SPI = no; # Freescale SPI - ARM SoC SPI
    SPI_LANTIQ_SSC = no; # Lantiq SSC SPI - MIPS/embedded SoC
    I2C_RK3X = no; # Rockchip I2C - ARM SoC I2C

    # Obsolete USB Ethernet Adapters (USB 1.1/2.0 era)
    USB_CATC = no; # CATC USB Ethernet - Obsolete USB 1.1 NIC
    USB_KAWETH = no; # Kawasaki LSI USB Ethernet - Ancient USB NIC
    USB_RTL8150 = no; # Realtek RTL8150 - USB 1.1 10Mbps NIC
    USB_PEGASUS = no; # Pegasus USB Ethernet - Old USB 1.1 NIC
    USB_NET_DM9601 = no; # Davicom DM9601 USB - Obsolete USB NIC
    USB_NET_SR9700 = no; # CoreChip SR9700 - Old USB 1.1 NIC
    USB_NET_SR9800 = no; # CoreChip SR9800 - Old USB 2.0 NIC
    USB_NET_GL620A = no; # Genesys GL620USB - Ancient USB host-to-host
    USB_NET_PLUSB = no; # Prolific PL2301/2302 - Old USB host-to-host
    USB_NET_MCS7830 = no; # MosChip MCS7830 - Obsolete USB NIC
    USB_NET_ZAURUS = no; # Zaurus USB net - PDA from 2000s
    USB_NET_CX82310_ETH = no; # Conexant CX82310 - Old USB modem
    USB_NET_KALMIA = no; # Samsung Kalmia - Old modem
    USB_HSO = no; # Option HSDPA modem - 3G USB modem
    USB_NET_INT51X1 = no; # Intellon PLC - Power line comms
    USB_CDC_PHONET = no; # Phonet USB - Nokia phone protocol
    USB_SIERRA_NET = no; # Sierra Wireless - Old 3G/4G modem
    USB_VL600 = no; # Samsung VL600 - Old LTE modem
    USB_NET_CH9200 = no; # QinHeng CH9200 - Obsolete USB NIC

    # --- Virtual test drivers ---
    VIDEO_VIVID = option no; # Virtual video test driver

    # --- Child options of disabled parents ---
    # When a parent config is forced off, its children vanish from kconfig.
    # common-config.nix sets these without `option`, so we override them here
    # with `option` to suppress "unused option" errors.
    AIC79XX_DEBUG_ENABLE = option no;
    AIC7XXX_DEBUG_ENABLE = option no;
    AIC94XX_DEBUG = option no;
    CHROMEOS_LAPTOP = option no;
    CHROMEOS_PSTORE = option no;
    CHROMEOS_TBMC = option no;
    CROS_EC = option no;
    CROS_EC_I2C = option no;
    CROS_EC_ISHTP = option no;
    CROS_EC_LPC = option no;
    CROS_EC_SPI = option no;
    CROS_KBD_LED_BACKLIGHT = option no;
    CEPH_FSCACHE = option no;
    CEPH_FS_POSIX_ACL = option no;
    CIFS_DFS_UPCALL = option no;
    CIFS_FSCACHE = option no;
    CIFS_UPCALL = option no;
    CIFS_XATTR = option no;
    DRM_NOUVEAU_SVM = option no;
    F2FS_FS_COMPRESSION = option no;
    INFINIBAND_IPOIB = option no;
    INFINIBAND_IPOIB_CM = option no;
    IP_VS_IPV6 = option no;
    IP_VS_PROTO_AH = option no;
    IP_VS_PROTO_ESP = option no;
    IP_VS_PROTO_TCP = option no;
    IP_VS_PROTO_UDP = option no;
    JOYSTICK_PSXPAD_SPI_FF = option no;
    MEGARAID_NEWGEN = option no;
    MTD_COMPLEX_MAPPINGS = option no;
    NFSD_V3_ACL = option no;
    NFSD_V4 = option no;
    NFSD_V4_SECURITY_LABEL = option no;
    NFS_LOCALIO = option no;
    NVME_TARGET_AUTH = option no;
    NVME_TARGET_PASSTHRU = option no;
    NVME_TARGET_TCP_TLS = option no;
    SCSI_LOWLEVEL_PCMCIA = option no;
    SLIP_COMPRESSED = option no;
    SLIP_SMART = option no;
    SQUASHFS_CHOICE_DECOMP_BY_MOUNT = option no;
    SQUASHFS_FILE_DIRECT = option no;
    SQUASHFS_LZ4 = option no;
    SQUASHFS_LZO = option no;
    SQUASHFS_XATTR = option no;
    SQUASHFS_XZ = option no;
    SQUASHFS_ZLIB = option no;
    SQUASHFS_ZSTD = option no;
    STAGING_MEDIA = option no;
    FUNCTION_GRAPH_RETVAL = option no;
    HID_BPF = option no;
    MEDIA_ATTACH = option no;
    PM_TRACE_RTC = option no;
  });

  networkingConfig = optionalAttrs cfg.networking {
    TCP_CONG_BBR = yes;
    DEFAULT_BBR = yes;
    NET_SCH_DEFAULT = yes;
    DEFAULT_FQ_CODEL = yes;
  };

  rustLtoConfig = optionalAttrs (cfg.rust && cfg.lto != "none") (forceAll {
    DEBUG_INFO_BTF = no;
    NOVA_CORE = option no;
    NET_SCH_BPF = option no;
    SCHED_CLASS_EXT = option no;
    MODULE_ALLOW_BTF_MISMATCH = option no;
    MODVERSIONS = no;
  });

  ltoConfig =
    {
      "full" = {
        LTO_CLANG_FULL = yes;
        LTO_CLANG_THIN = mkForce no;
      };
      "thin" = {
        LTO_CLANG_THIN = yes;
        LTO_CLANG_FULL = mkForce no;
      };
      "none" = { };
    }
    .${cfg.lto};

  cpuArchConfig = optionalAttrs (cfg.cpuArch != null) {
    ${cfg.cpuArch} = yes;
  };

  bunkernel = pkgs.linuxKernel.buildLinux {
    pname = "linux-bunker";
    stdenv = llvmStdenv;
    src = kernelSrc;
    version = fullVersion;
    modDirVersion = "${fullVersion}-bunker";
    inherit kernelPatches;

    structuredExtraConfig =
      baseConfig
      // interactiveConfig
      // hardenedConfig
      // trimmedConfig
      // networkingConfig
      // rustLtoConfig
      // ltoConfig
      // cpuArchConfig;

    extraMeta = {
      branch = majorMinor;
      description = "Bunker kernel";
    };
  };

  bunkernel' = bunkernel.overrideAttrs (old: {
    # The Clang+LTO+Rust kernel binary embeds build tool store paths
    # (CC, LD, RUSTC, etc.) that Nix's reference scanner picks up as
    # runtime dependencies.  The kernel image is loaded by the bootloader
    # and has zero legitimate runtime store-path dependencies, so we can
    # safely discard all detected references from $out.
    # Requires __structuredAttrs = true (already set by nixpkgs' buildLinux).
    unsafeDiscardReferences = (old.unsafeDiscardReferences or { }) // {
      out = true;
    };

    postInstall =
      builtins.replaceStrings
        [ "# Keep whole scripts dir" ]
        [
          ''
            # Keep rust Makefile and source files for rust-analyzer support
                      [ -f rust/Makefile ] && chmod u-w rust/Makefile
                      find rust -type f -name '*.rs' -print0 | xargs -0 -r chmod u-w

                      # Keep whole scripts dir''
        ]
        (old.postInstall or "");
  });

  # Discard kernel.dev references from out-of-tree kernel modules at Nix
  # scan time.  Out-of-tree modules (.ko.zst) embed KBUILD_OUTPUT in their
  # .modinfo section; zstd sometimes stores this path verbatim in a literal
  # block.  system.replaceRuntimeDependencies patches raw bytes inside those
  # compressed frames, corrupting the zstd content checksum and causing
  # modprobe/insmod to fail with EINVAL at boot.  unsafeDiscardReferences
  # breaks the toolchain reference during the Nix build scan instead,
  # keeping the closure small without touching any compressed data.
  kernelPackage = (pkgs.linuxKernel.packagesFor bunkernel').extend (
    _: prev:
    lib.optionalAttrs (prev ? bcachefs-tools) {
      bcachefs-tools = prev.bcachefs-tools.overrideAttrs (old: {
        unsafeDiscardReferences = (old.unsafeDiscardReferences or { }) // {
          out = true;
        };
      });
    }
    // lib.optionalAttrs (prev ? bcachefs) {
      bcachefs = prev.bcachefs.overrideAttrs (old: {
        unsafeDiscardReferences = (old.unsafeDiscardReferences or { }) // {
          out = true;
        };
      });
    }
  );
in
{
  options.bunker.kernel = {
    enable = mkEnableOption "Bunker kernel";

    version = mkOption {
      type = types.enum [
        "6.18"
        "6.19"
      ];
      default = "6.19";
      description = "Linux kernel major.minor version. Automatically resolves to the latest stable point release.";
    };

    interactive = mkOption {
      type = types.bool;
      default = true;
      description = "Enable interactive/desktop performance patches (preempt, BFQ, RCU tuning, etc.).";
    };

    hardened = mkOption {
      type = types.bool;
      default = true;
      description = "Enable linux-hardened security patches (CFI, RANDSTRUCT, slab hardening, etc.).";
    };

    trimmed = mkOption {
      type = types.bool;
      default = true;
      description = "Disable dead/legacy modules and subsystems (old hardware, dead protocols, unused filesystems, etc.).";
    };

    networking = mkOption {
      type = types.bool;
      default = true;
      description = "Enable networking patches (BBRv3, FQ-Codel).";
    };

    drivers = mkOption {
      type = types.bool;
      default = true;
      description = "Enable driver patches (ACS override, AMDGPU, HDMI, Bluetooth quirks, etc.).";
    };

    extras = mkOption {
      type = types.bool;
      default = true;
      description = "Enable extra patches (sched_ext, v4l2loopback, Clang Polly, micro-arch targets, etc.).";
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
      default = "full";
      description = "LTO mode for Clang.";
    };

    rust = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Rust support in the kernel.";
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

      boot.kernelPackages = kernelPackage;
    }

    (mkIf cfg.hardened {
      boot.kernel.sysctl = {
        # Disable Magic SysRq key — potential security concern.
        "kernel.sysrq" = 0;
        # Hide kptrs even for processes with CAP_SYSLOG.
        "kernel.kptr_restrict" = 2;
        # Disable bpf() JIT (eliminates spray attacks).
        "net.core.bpf_jit_enable" = false;
        # Disable ftrace debugging.
        "kernel.ftrace_enabled" = false;
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
        "module.sig_enforce=1"
        "lockdown=confidentiality"
        "page_alloc.shuffle=1"
        "sysrq_always_enabled=0"
        "kcore=off"
      ];
    })

    (mkIf cfg.interactive {
      boot.kernelParams = [
        "fbcon=nodefer"
      ];
    })
  ]);
}
