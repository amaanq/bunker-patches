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

  # Map user-facing major.minor → latest stable point release
  stableRelease = {
    "6.18" = "6.18.10";
    "6.19" = "6.19";
  };

  resolvedVersion = stableRelease.${cfg.version}
    or (throw "bunker: unsupported kernel version ${cfg.version}");

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
      drivers = [ "0204" "0206" ];
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
    MODULE_COMPRESS_ZSTD = mkForce yes;
    MODULE_COMPRESS_XZ = mkForce no;
  };

  interactiveConfig = optionalAttrs cfg.interactive {
    PREEMPT = mkOverride 90 yes;
    PREEMPT_VOLUNTARY = mkOverride 90 no;
    HZ = freeform "1000";
    HZ_1000 = yes;
    IOSCHED_BFQ = mkOverride 90 yes;
    MQ_IOSCHED_ADIOS = yes;
    TRANSPARENT_HUGEPAGE_ALWAYS = mkForce yes;
    TRANSPARENT_HUGEPAGE_MADVISE = mkForce no;
    MQ_IOSCHED_KYBER = mkForce no;
    BLK_WBT = mkForce no;
    BLK_WBT_MQ = mkForce (option no);
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
    X86_AMD_PSTATE = yes;
    X86_AMD_PSTATE_DEFAULT_MODE = freeform "3";
  };

  hardenedConfig = optionalAttrs cfg.hardened {
    STRICT_DEVMEM = mkForce (option no);
    IO_STRICT_DEVMEM = mkForce (option no);
    CFI = yes;
    CFI_PERMISSIVE = no;
    ZERO_CALL_USED_REGS = yes;
    SECURITY_SAFESETID = yes;

    # --- Dead network hardware ---
    ARCNET = mkForce (option no); # 1970s token-passing network
    FDDI = mkForce (option no); # 1980s fiber ring
    HIPPI = mkForce (option no); # 1990s supercomputer interconnect
    PLIP = mkForce (option no); # Parallel Line IP
    EQUALIZER = mkForce (option no); # Serial/PLIP link load balancer

    # --- Dead network protocols ---
    ATALK = mkForce (option no); # Appletalk
    ATM = mkForce (option no); # Async Transfer Mode
    AX25 = mkForce (option no); # Amateur radio X.25
    CAN = mkForce (option no); # Controller Area Network
    DECNET = mkForce (option no); # DECnet
    HAMRADIO = mkForce (option no); # Amateur radio umbrella (ax25/netrom/rose)
    IEEE802154 = mkForce (option no); # Wireless sensor networks
    IP_DCCP = mkForce (option no); # Datagram Congestion Control
    IP_SCTP = mkForce (option no); # Stream Control Transmission
    IPX = mkForce (option no); # Internetwork Packet Exchange
    NETROM = mkForce (option no); # Amateur radio NetRom
    N_HDLC = mkForce (option no); # HDLC line discipline
    ROSE = mkForce (option no); # Amateur radio ROSE
    RDS = mkForce (option no); # Reliable Datagram Sockets
    TIPC = mkForce (option no); # Transparent IPC
    X25 = mkForce (option no); # X.25 packet switching
    AF_RXRPC = mkForce (option no); # RxRPC sessions (only for AFS)
    AF_KCM = mkForce (option no); # Kernel Connection Multiplexor
    PHONET = mkForce (option no); # Nokia Phonet
    CAIF = mkForce (option no); # ST-Ericsson modem IPC
    "6LOWPAN" = mkForce (option no); # IPv6 over low-power networks
    NFC = mkForce (option no); # Near Field Communication
    WIMAX = mkForce (option no); # WiMAX (dead standard)
    MCTP = mkForce (option no); # Management Component Transport
    # QRTR: can't disable — ath11k/ath12k WiFi drivers `select QRTR`
    HSR = mkForce (option no); # High-availability Seamless Redundancy
    # MPLS: can't disable — OPENVSWITCH (common-config.nix) selects it
    BATMAN_ADV = mkForce (option no); # B.A.T.M.A.N. mesh
    NET_DSA = mkForce (option no); # Distributed Switch Architecture

    # --- Server/cloud networking ---
    GENEVE = mkForce (option no); # Cloud overlay
    NET_TEAM = mkForce (option no); # Network teaming
    MACSEC = mkForce (option no); # 802.1AE MAC encryption
    NET_SWITCHDEV = mkForce (option no); # Switch offload

    # --- Dead/unused filesystems ---
    ADFS_FS = mkForce (option no);
    AFFS_FS = mkForce (option no);
    AFS_FS = mkForce (option no); # Andrew File System
    BEFS_FS = mkForce (option no);
    BFS_FS = mkForce (option no);
    CEPH_FS = mkForce (option no);
    CIFS = mkForce (option no); # NixOS might enable
    CRAMFS = mkForce (option no);
    EFS_FS = mkForce (option no);
    EROFS_FS = mkForce (option no);
    F2FS_FS = mkForce (option no);
    GFS2_FS = mkForce (option no);
    HFS_FS = mkForce (option no);
    HFSPLUS_FS = mkForce (option no);
    HPFS_FS = mkForce (option no);
    JFFS2_FS = mkForce (option no);
    JFS_FS = mkForce (option no);
    MINIX_FS = mkForce (option no);
    NILFS2_FS = mkForce (option no);
    OCFS2_FS = mkForce (option no);
    OMFS_FS = mkForce (option no);
    ORANGEFS_FS = mkForce (option no);
    QNX4FS_FS = mkForce (option no);
    QNX6FS_FS = mkForce (option no);
    REISERFS_FS = mkForce (option no);
    SMB_SERVER = mkForce (option no); # ksmbd
    SQUASHFS = mkForce (option no); # NixOS might enable
    SYSV_FS = mkForce (option no);
    UDF_FS = mkForce (option no);
    VXFS_FS = mkForce (option no); # freevxfs
    ZONEFS_FS = mkForce (option no);
    "9P_FS" = mkForce (option no); # Plan 9
    CODA_FS = mkForce (option no); # Coda distributed filesystem
    ROMFS_FS = mkForce (option no); # ROM filesystem (embedded)
    UBIFS_FS = mkForce (option no); # UBI flash filesystem (embedded)
    NTFS_FS = mkForce (option no); # Old NTFS driver (NTFS3 supersedes)
    MSDOS_FS = mkForce (option no); # 8.3 FAT (VFAT supersedes)

    # --- Dead subsystems ---
    FIREWIRE = mkForce (option no); # IEEE 1394
    INFINIBAND = mkForce (option no); # RDMA/InfiniBand
    ISDN = mkForce (option no); # ISDN telephony
    PCMCIA = mkForce (option no); # CardBus
    PARPORT = mkForce (option no); # Parallel port
    INPUT_JOYSTICK = mkForce no; # Disables all gameport joystick drivers
    GAMEPORT = mkForce (option no); # Legacy gameport (freed by INPUT_JOYSTICK=n)
    COMEDI = mkForce (option no); # Data acquisition
    GREYBUS = mkForce (option no); # Project Ara
    STAGING = mkForce (option no); # Experimental drivers

    # --- Dead buses/subsystems (industrial/embedded/ARM) ---
    VME_BUS = mkForce (option no); # VMEbus (1980s industrial crate bus)
    RAPIDIO = mkForce (option no); # Telecom/DSP interconnect
    IPACK = mkForce (option no); # IndustryPack automation
    SIOX = mkForce (option no); # Eckelmann industrial protocol
    HSI = mkForce (option no); # Nokia modem serial (one dead chipset)
    MOST = mkForce (option no); # Automotive infotainment bus
    SPMI = mkForce (option no); # Qualcomm ARM power management bus
    SLIMBUS = mkForce (option no); # Qualcomm ARM audio codec bus
    INTERCONNECT = mkForce (option no); # ARM SoC interconnect framework
    # W1: can't disable — BATTERY_DS2780/DS2781 (common-config.nix) select it
    NTB = mkForce (option no); # Non-Transparent Bridge (multi-host PCIe)
    COUNTER = mkForce (option no); # Embedded quadrature encoders
    GNSS = mkForce (option no); # GPS/GNSS receivers over serial
    MELLANOX_PLATFORM = mkForce (option no); # Mellanox switch ASICs (not ConnectX NICs)
    PCCARD = mkForce (option no); # 16-bit PC Card (dead since ~2005)
    AGP = mkForce (option no); # Accelerated Graphics Port (all GPUs use PCIe)
    EISA = mkForce (option no); # Extended ISA bus (dead since ~2000)
    I3C = mkForce (option no); # MIPI I3C bus (embedded/phone only)
    MTD = mkForce (option no); # Memory Technology Devices (raw flash, embedded)

    # --- Dead memory technologies ---
    # LIBNVDIMM: can't disable — arch/x86/Kconfig unconditionally `select LIBNVDIMM`
    DEV_DAX = mkForce (option no); # DAX devices for persistent memory
    CXL_BUS = mkForce (option no); # Compute Express Link (bleeding-edge server)

    # --- Dead GPU drivers ---
    DRM_SIS = mkForce (option no); # SiS GPUs (dead vendor ~2008)
    DRM_VIA = mkForce (option no); # VIA GPUs (dead GPU division)
    DRM_SAVAGE = mkForce (option no); # S3 Savage GPUs (dead ~2003)
    DRM_NOUVEAU = mkForce (option no); # NVIDIA open-source (use proprietary or AMD)
    DRM_RADEON = mkForce (option no); # Pre-GCN AMD GPUs (pre-2012, use AMDGPU)

    # --- Dead misc hardware ---
    MEMSTICK = mkForce (option no); # Sony Memory Stick (dead format)
    PHONE = mkForce (option no); # ISA/PCI telephony cards
    AUXDISPLAY = mkForce (option no); # Character LCD displays (parallel port)
    ACRN_GUEST = mkForce (option no); # ACRN hypervisor guest (dead hypervisor)
    RAW_DRIVER = mkForce (option no); # /dev/raw (deprecated, use O_DIRECT)
    # DCA: can't disable — INTEL_IOATDMA (common-config.nix) selects it
    HANGCHECK_TIMER = mkForce (option no); # Server cluster heartbeat
    DEVPORT = mkForce (option no); # /dev/port I/O port access
    HOTPLUG_PCI_CPCI = mkForce (option no); # CompactPCI hotplug (industrial)
    BLK_DEV_DRBD = mkForce (option no); # DRBD distributed block replication
    MOUSE_SERIAL = mkForce (option no); # Serial mice (RS-232)
    SERIO_SERPORT = mkForce (option no); # Serial port input devices
    SND_ISA = mkForce (option no); # ISA sound cards
    # SND_OPL3_LIB: can't disable — PCI sound cards (FM801, etc.) select it
    SND_OPL4_LIB = mkForce (option no); # OPL4 synth (ISA-era)
    # SND_MPU401_UART: can't disable — PCI sound cards (FM801, YMFPCI, etc.) select it
    SND_SB_COMMON = mkForce (option no); # SoundBlaster common (ISA-era)
    SND_OSSEMUL = mkForce (option no); # OSS API emulation (deprecated ~20yr)
    SND_PCM_OSS = mkForce (option no); # OSS /dev/dsp emulation
    SND_MIXER_OSS = mkForce (option no); # OSS /dev/mixer emulation
    SND_SEQUENCER_OSS = mkForce (option no); # OSS sequencer emulation
    SND_SERIAL_U16550 = mkForce (option no); # UART16550 serial MIDI

    # --- Dead input devices ---
    JOYSTICK_ANALOG = mkForce (option no); # Analog gameport joystick
    MOUSE_ATIXL = mkForce (option no); # ATI XL bus mouse
    MOUSE_INPORT = mkForce (option no); # Microsoft InPort bus mouse
    MOUSE_LOGIBM = mkForce (option no); # Logitech bus mouse
    KEYBOARD_LKKBD = mkForce (option no); # DEC LK201/LK401 (serial)
    KEYBOARD_NEWTON = mkForce (option no); # Apple Newton keyboard
    KEYBOARD_SUNKBD = mkForce (option no); # Sun keyboard (serial)
    KEYBOARD_STOWAWAY = mkForce (option no); # Stowaway portable keyboard

    # --- Dead platform drivers ---
    SONYPI = mkForce (option no); # Old Sony VAIO programmable I/O
    ACPI_CMPC = mkForce (option no); # Classmate PC (dead OLPC-like)
    COMPAL_LAPTOP = mkForce (option no); # Compal IFL90/JFL92 laptops
    AMILO_RFKILL = mkForce (option no); # Fujitsu Amilo RF kill
    TOSHIBA_HAPS = mkForce (option no); # Toshiba HDD Active Protection (SSD era)

    # --- Dead block/storage hardware ---
    BLK_DEV_FD = mkForce (option no); # Floppy disk
    PATA_LEGACY = mkForce (option no); # ISA-era parallel ATA
    PATA_ISAPNP = mkForce (option no); # ISA PnP parallel ATA
    BLK_DEV_DAC960 = mkForce (option no); # Mylex DAC960 RAID (dead vendor)
    BLK_DEV_UMEM = mkForce (option no); # Micro Memory MM5415 RAM card

    # --- Dead cpufreq drivers ---
    X86_SPEEDSTEP_CENTRINO = mkForce (option no); # Pentium M/Centrino
    X86_SPEEDSTEP_ICH = mkForce (option no); # Old ICH chipsets
    X86_SPEEDSTEP_SMI = mkForce (option no); # SMI-based (ancient laptops)
    X86_SPEEDSTEP_LIB = mkForce (option no); # SpeedStep common code
    X86_P4_CLOCKMOD = mkForce (option no); # Pentium 4 clock modulation
    X86_POWERNOW_K6 = mkForce (option no); # AMD K6
    X86_POWERNOW_K7 = mkForce (option no); # AMD K7 (Athlon)
    X86_POWERNOW_K8 = mkForce (option no); # AMD K8 (Athlon 64)
    X86_GX_SUSPMOD = mkForce (option no); # Cyrix/NatSemi Geode GX
    X86_LONGHAUL = mkForce (option no); # VIA C3
    X86_E_POWERSAVER = mkForce (option no); # VIA C7
    X86_LONGRUN = mkForce (option no); # Transmeta (bankrupt)

    # --- Dead misc drivers ---
    APPLICOM = mkForce (option no); # Industrial fieldbus cards
    PHANTOM = mkForce (option no); # SensAble PHANToM haptic device
    # TIFM_CORE: can't disable — MMC_TIFM_SD (common-config.nix) selects it
    TELCLOCK = mkForce (option no); # Telecom clock (MCPL0010)
    ECHO = mkForce (option no); # Telephony echo cancellation
    RPMSG = mkForce (option no); # Remote Processor Messaging (ARM)
    REMOTEPROC = mkForce (option no); # Remote Processor framework (ARM)

    # --- Dead media ---
    MEDIA_ANALOG_TV_SUPPORT = mkForce (option no); # Analog TV (shut off globally)
    MEDIA_DIGITAL_TV_SUPPORT = mkForce (option no); # DVB digital TV tuners
    DVB_CORE = mkForce (option no); # Digital Video Broadcasting
    MEDIA_SDR_SUPPORT = mkForce (option no); # Software defined radio

    # --- Dead network transports ---
    SLIP = mkForce (option no); # Serial Line IP (dialup)
    ATA_OVER_ETH = mkForce (option no); # ATA over Ethernet
    LAPB = mkForce (option no); # X.25 link layer
    NET_9P = mkForce (option no); # Plan 9 network transport
    PKTGEN = mkForce (option no); # Kernel packet generator (testing)
    N_GSM = mkForce (option no); # GSM 0710 mux for old serial modems
    BT_CMTP = mkForce (option no); # Bluetooth CAPI (ISDN over BT)

    # --- Server block/storage ---
    BLK_DEV_NBD = mkForce (option no); # Network block device
    BLK_DEV_RBD = mkForce (option no); # Ceph/RADOS block
    TARGET_CORE = mkForce (option no); # SCSI target
    ISCSI_TCP = mkForce (option no); # iSCSI initiator
    NVME_TARGET = mkForce (option no); # NVMe-oF target

    # --- Unused large subsystems ---
    # AUDIT: can't disable — AppArmor (NixOS default LSM) selects it
    IP_VS = mkForce (option no); # IPVS load balancer (~30k LOC, only k8s IPVS mode)
    NFSD = mkForce (option no); # NFS server (~25k LOC, client kept via NFS_FS)
    QUOTA = mkForce (option no); # Disk quotas (~10k LOC, multi-user server feature)

    # --- Legacy/deprecated ---
    USELIB = mkForce (option no); # a.out uselib() syscall
    SYSFS_SYSCALL = mkForce (option no); # old sysfs() syscall
    PCSPKR_PLATFORM = mkForce (option no); # PC speaker
    KEXEC = mkForce (option no); # kexec (disabled at runtime anyway)
    CDROM_PKTCDVD = mkForce (option no); # Packet writing to CD/DVDs
    EFI_VARS = mkForce (option no); # Old sysfs EFI vars (EFIVAR_FS supersedes)
    RAID_AUTODETECT = mkForce (option no); # Legacy MD RAID autodetect
    FB_DEVICE = mkForce (option no); # Legacy /dev/fb* (DRM/KMS supersedes)
    FRAMEBUFFER_CONSOLE_LEGACY_ACCELERATION = mkForce (option no); # Legacy fbcon hw accel
    X86_IOPL_IOPERM = mkForce (option no); # IOPL/IOPERM syscalls (KSPP)
    X86_VSYSCALL_EMULATION = mkForce (option no); # Legacy vsyscall page (KSPP)
    X86_X32_ABI = mkForce (option no); # x32 ABI (exotic, deprecated)
    X86_MPPARSE = mkForce (option no); # MPS tables (pre-ACPI SMP)
    X86_EXTENDED_PLATFORM = mkForce (option no); # Non-standard x86 platforms (SGI UV, etc.)
    GART_IOMMU = mkForce (option no); # AMD K8-era GART IOMMU (modern uses AMD-Vi)
    REROUTE_FOR_BROKEN_BOOT_IRQS = mkForce (option no); # Workaround for ancient BIOS IRQ routing
    MSDOS_PARTITION = mkForce (option no); # MBR partition table (GPT era)
    ACCESSIBILITY = mkForce (option no); # Speakup screen reader
    SCSI_LOWLEVEL = mkForce (option no); # Legacy SCSI HBA drivers (Adaptec, BusLogic, etc.)
    X86_SGX = mkForce (option no); # Intel SGX enclaves
    SECURITY_SELINUX = mkForce (option no); # SELinux (~20k LOC, NixOS uses AppArmor)
    SECURITY_TOMOYO = mkForce (option no); # TOMOYO (~10k LOC, unused on NixOS)

    # --- Obsolete crypto ---
    CRYPTO_USER_API_ENABLE_OBSOLETE = mkForce (option no); # Gates ANUBIS/KHAZAD/SEED/TEA
    CRYPTO_FCRYPT = mkForce (option no); # fcrypt (only for dead AFS/RxRPC)

    # --- Debug/testing infrastructure ---
    KCOV = mkForce (option no); # Syzkaller fuzzing infra
    GCOV_KERNEL = mkForce (option no); # Kernel code coverage
    FAULT_INJECTION = mkForce (option no); # Debug fault injection framework
    KASAN = mkForce (option no); # Kernel Address Sanitizer
    KMEMLEAK = mkForce (option no); # Kernel memory leak detector
    PROVE_LOCKING = mkForce (option no); # Lock dependency validator (lockdep)
    LOCK_STAT = mkForce (option no); # Lock contention statistics
    NOTIFIER_ERROR_INJECTION = mkForce (option no); # Error injection for notifier chains
    DEBUG_PAGEALLOC = mkForce (option no); # Debug page allocation
    KUNIT = mkForce (option no); # Kernel unit testing framework
    EXT4_DEBUG = mkForce (option no); # ext4 debug
    JBD2_DEBUG = mkForce (option no); # ext4 journaling debug
    SLUB_DEBUG = mkForce (option no); # SLUB allocator debug
    DYNAMIC_DEBUG = mkForce (option no); # Runtime pr_debug control

    # --- VM guest (not applicable to bare-metal desktop) ---
    DRM_VIRTIO_GPU = mkForce (option no); # Virtio GPU
    VIDEO_VIVID = mkForce (option no); # Virtual video test driver

    # --- Child options of disabled parents ---
    # When a parent config is forced off, its children vanish from kconfig.
    # common-config.nix sets these without `option`, so we override them here
    # with `option` to suppress "unused option" errors.
    AIC79XX_DEBUG_ENABLE = mkForce (option no);
    AIC7XXX_DEBUG_ENABLE = mkForce (option no);
    AIC94XX_DEBUG = mkForce (option no);
    CEPH_FSCACHE = mkForce (option no);
    CEPH_FS_POSIX_ACL = mkForce (option no);
    CIFS_DFS_UPCALL = mkForce (option no);
    CIFS_FSCACHE = mkForce (option no);
    CIFS_UPCALL = mkForce (option no);
    CIFS_XATTR = mkForce (option no);
    DRM_NOUVEAU_SVM = mkForce (option no);
    F2FS_FS_COMPRESSION = mkForce (option no);
    INFINIBAND_IPOIB = mkForce (option no);
    INFINIBAND_IPOIB_CM = mkForce (option no);
    IP_VS_IPV6 = mkForce (option no);
    IP_VS_PROTO_AH = mkForce (option no);
    IP_VS_PROTO_ESP = mkForce (option no);
    IP_VS_PROTO_TCP = mkForce (option no);
    IP_VS_PROTO_UDP = mkForce (option no);
    JOYSTICK_PSXPAD_SPI_FF = mkForce (option no);
    MEGARAID_NEWGEN = mkForce (option no);
    MTD_COMPLEX_MAPPINGS = mkForce (option no);
    NFSD_V3_ACL = mkForce (option no);
    NFSD_V4 = mkForce (option no);
    NFSD_V4_SECURITY_LABEL = mkForce (option no);
    NFS_LOCALIO = mkForce (option no);
    NVME_TARGET_AUTH = mkForce (option no);
    NVME_TARGET_PASSTHRU = mkForce (option no);
    NVME_TARGET_TCP_TLS = mkForce (option no);
    SCSI_LOWLEVEL_PCMCIA = mkForce (option no);
    SLIP_COMPRESSED = mkForce (option no);
    SLIP_SMART = mkForce (option no);
    SQUASHFS_CHOICE_DECOMP_BY_MOUNT = mkForce (option no);
    SQUASHFS_FILE_DIRECT = mkForce (option no);
    SQUASHFS_LZ4 = mkForce (option no);
    SQUASHFS_LZO = mkForce (option no);
    SQUASHFS_XATTR = mkForce (option no);
    SQUASHFS_XZ = mkForce (option no);
    SQUASHFS_ZLIB = mkForce (option no);
    SQUASHFS_ZSTD = mkForce (option no);
    STAGING_MEDIA = mkForce (option no);
    X86_SGX_KVM = mkForce (option no);
  };

  networkingConfig = optionalAttrs cfg.networking {
    TCP_CONG_BBR = yes;
    DEFAULT_BBR = yes;
    NET_SCH_DEFAULT = yes;
    DEFAULT_FQ_CODEL = yes;
  };

  rustLtoConfig = optionalAttrs (cfg.rust && cfg.lto != "none") {
    DEBUG_INFO_BTF = mkForce no;
    NOVA_CORE = mkForce (option no);
    NET_SCH_BPF = mkForce (option no);
    SCHED_CLASS_EXT = mkForce (option no);
    MODULE_ALLOW_BTF_MISMATCH = mkForce (option no);
    MODVERSIONS = mkForce no;
  };

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
      // networkingConfig
      // rustLtoConfig
      // ltoConfig
      // cpuArchConfig;

    extraMeta = {
      branch = majorMinor;
      description = "Bunker kernel";
    };
  };

  kernelPackage = pkgs.linuxKernel.packagesFor (
    bunkernel.overrideAttrs (old: {
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
    })
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
      type = types.nullOr (types.enum [
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
      ]);
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
