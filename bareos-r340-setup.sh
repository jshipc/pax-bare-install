#!/usr/bin/env bash
# ==============================================================================
# r340-bareos-full-setup.sh
#
# One-shot setup for a Dell R340 Bareos server on Ubuntu 24.04/25.04:
#   - Build a LARGE DISK POOL on SAS drives (ZFS raidz2 OR LVM+XFS).
#   - Bind-mount the pool to /var/lib/bareos/storage (so Bareos uses it).
#   - Add the official Bareos repository (CURRENT) and install:
#       bareos, bareos-database-postgresql, bareos-webui
#
# Safety / Idempotence:
#   - Will not wipe disks unless WIPE_DISKS=true.
#   - Will not recreate pools/volumes if they already exist.
#   - Fails fast on repo key 404 to avoid "gpg: no valid OpenPGP data found".
#
# Customize the TOGGLES section below, then run as root.
# ==============================================================================

set -euo pipefail

# ── Pretty printing helpers ────────────────────────────────────────────────────
info()  { printf "\033[1;36m[INFO]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[ OK ]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
fail()  { printf "\033[1;31m[FAIL]\033[0m %s\n" "$*"; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

# ── TOGGLES: adjust to your environment ───────────────────────────────────────
# Choose how to build the big backup pool on SAS disks:
POOL_MODE="ZFS"                # "ZFS"  or  "LVM"

# List ONLY the SAS data disks (NOT the BOSS SSDs). Edit as needed.
SAS_DISKS=(/dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf /dev/sdg /dev/sdh)

# DANGER: if true, zaps partition tables & signatures before creating the pool.
WIPE_DISKS=false               # true/false

# Where the large pool mounts, and where Bareos expects FileStorage by default.
POOL_MNT="/srv/bareos-disk"
BAREOS_STORAGE_DIR="/var/lib/bareos/storage"
BIND_MOUNT=true                # bind POOL_MNT → /var/lib/bareos/storage

# ZFS layout (used if POOL_MODE=ZFS)
ZPOOL_NAME="bareospool"
ZFS_LAYOUT="raidz2"            # raidz2 recommended for 6–10 disks
ZFS_DATASET="${ZPOOL_NAME}/disk"
# Sensible dataset options for large sequential workloads (backups)
ZFS_OPTS=(-O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl -O recordsize=1M)

# LVM layout (used if POOL_MODE=LVM)
VG_NAME="bareos-vg"
LV_NAME="bareos-lv"
LV_SIZE="100%FREE"            # or "8T"
LVM_FS="xfs"                  # xfs recommended for big files

# Optional: force Bareos series via env var SERIES= (e.g., SERIES=xUbuntu_24.04)
# Otherwise we detect from OS version.
# ──────────────────────────────────────────────────────────────────────────────

# ── Detect Bareos repo "series" string (xUbuntu_25.04, xUbuntu_24.04, …) ─────
detect_series() {
  local ver=""
  if command -v lsb_release >/dev/null 2>&1; then
    ver="$(lsb_release -sr)"
  elif [[ -f /etc/os-release ]]; then
    ver="$(. /etc/os-release; echo "${VERSION_ID:-}")"
  fi
  case "$ver" in
    25.04) echo "xUbuntu_25.04" ;;
    24.04) echo "xUbuntu_24.04" ;;
    22.04) echo "xUbuntu_22.04" ;;
    *)     warn "Unknown Ubuntu VERSION_ID '$ver'; defaulting to xUbuntu_24.04"; echo "xUbuntu_24.04" ;;
  esac
}
SERIES="${SERIES:-$(detect_series)}"
info "Using Bareos repository series: ${SERIES}"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
need lsblk; need awk
mkdir -p "$POOL_MNT" "$BAREOS_STORAGE_DIR"

info "Verifying listed SAS disks exist and are block devices:"
for d in "${SAS_DISKS[@]}"; do
  [[ -b "$d" ]] || fail "$d is not a block device; update SAS_DISKS"
  echo "  - $d ($(lsblk -dn -o SIZE,MODEL "$d" | awk '{print $1" "$2}'))"
done

# ── Optional destructive wipe ─────────────────────────────────────────────────
if [[ "$WIPE_DISKS" == "true" ]]; then
  need sgdisk; need wipefs
  warn "WIPE_DISKS=true → will ERASE partition tables & FS signatures on: ${SAS_DISKS[*]}"
  read -r -p "Type 'YES' to continue: " x; [[ "$x" == "YES" ]] || fail "Aborted."
  for d in "${SAS_DISKS[@]}"; do
    info "Wiping $d"
    sgdisk --zap-all "$d" || true
    wipefs -a "$d" || true
  done
  ok "Wipe complete"
fi

# ── Build the data pool ───────────────────────────────────────────────────────
if [[ "$POOL_MODE" == "ZFS" ]]; then
  info "Installing ZFS utilities…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y zfsutils-linux

  need zpool; need zfs

  info "Creating ZFS pool (if absent): $ZPOOL_NAME  layout: $ZFS_LAYOUT  disks: ${SAS_DISKS[*]}"
  if ! zpool list "$ZPOOL_NAME" &>/dev/null; then
    zpool create -f "$ZPOOL_NAME" "$ZFS_LAYOUT" "${SAS_DISKS[@]}"
  else
    ok "ZFS pool $ZPOOL_NAME already exists"
  fi

  info "Ensuring dataset exists with tuned options"
  if ! zfs list "$ZFS_DATASET" &>/dev/null; then
    zfs create "${ZFS_OPTS[@]}" "$ZFS_DATASET"
  fi
  zfs set mountpoint="$POOL_MNT" "$ZFS_DATASET"
  zfs mount "$ZFS_DATASET" || true
  ok "ZFS dataset mounted at $POOL_MNT"

elif [[ "$POOL_MODE" == "LVM" ]]; then
  info "Installing LVM & filesystem tools…"
  apt-get update -y
  apt-get install -y lvm2 xfsprogs
  need pvcreate; need vgcreate; need lvcreate

  info "Creating PVs if missing"
  for d in "${SAS_DISKS[@]}"; do
    if ! pvs --noheadings "$d" &>/dev/null; then
      pvcreate -ff -y "$d"
      echo "  - pvcreate $d"
    else
      echo "  - PV exists on $d"
    fi
  done

  info "Creating VG $VG_NAME if missing"
  if ! vgdisplay "$VG_NAME" &>/dev/null; then
    vgcreate "$VG_NAME" "${SAS_DISKS[@]}"
  else
    ok "VG $VG_NAME exists"
  fi

  info "Creating LV $LV_NAME if missing"
  if ! lvdisplay "/dev/$VG_NAME/$LV_NAME" &>/dev/null; then
    lvcreate -n "$LV_NAME" -l "$LV_SIZE" "$VG_NAME"
  else
    ok "LV $LV_NAME exists"
  fi

  LV_DEV="/dev/$VG_NAME/$LV_NAME"
  FS_TYPE="$(lsblk -no FSTYPE "$LV_DEV" || true)"
  if [[ -z "$FS_TYPE" ]]; then
    info "Making filesystem $LVM_FS on $LV_DEV"
    mkfs."$LVM_FS" -f "$LV_DEV"
  else
    ok "$LV_DEV already formatted as $FS_TYPE"
  fi

  # mount via fstab (UUID)
  UUID=$(blkid -s UUID -o value "$LV_DEV")
  grep -q "$UUID" /etc/fstab || {
    info "Adding $LV_DEV to /etc/fstab"
    echo "UUID=$UUID  $POOL_MNT  $LVM_FS  noatime,nodiratime  0 2" >> /etc/fstab
  }
  mountpoint -q "$POOL_MNT" || mount "$POOL_MNT"
  ok "LVM volume mounted at $POOL_MNT"

else
  fail "POOL_MODE must be 'ZFS' or 'LVM'"
fi

# ── Bind-mount big pool → Bareos storage path (keeps Bareos defaults simple) ──
if [[ "$BIND_MOUNT" == "true" ]]; then
  info "Setting up bind-mount: $POOL_MNT  →  $BAREOS_STORAGE_DIR"
  mkdir -p "$BAREOS_STORAGE_DIR"
  if ! grep -qE "^[[:space:]]*${POOL_MNT}[[:space:]]+${BAREOS_STORAGE_DIR}[[:space:]]+none[[:space:]]+bind" /etc/fstab; then
    echo "$POOL_MNT  $BAREOS_STORAGE_DIR  none  bind  0 0" >> /etc/fstab
  fi
  mountpoint -q "$BAREOS_STORAGE_DIR" || mount "$BAREOS_STORAGE_DIR"
  ok "Bind-mount active"
fi

# Ensure ownership for Bareos SD
chown -R bareos:bareos "$BAREOS_STORAGE_DIR" 2>/dev/null || true

# ── Add Bareos repo (CURRENT) with 404 guard, then install Bareos ─────────────
info "Preparing to add Bareos apt repo (CURRENT) for ${SERIES}"
apt-get install -y curl gpg ca-certificates apt-transport-https

KEY_URL="https://download.bareos.org/current/${SERIES}/Release.key"
KEYRING="/usr/share/keyrings/bareos.gpg"
LISTFILE="/etc/apt/sources.list.d/bareos.list"
TMPKEY="$(mktemp)"

info "Downloading repo key: $KEY_URL"
if ! curl -fSLo "$TMPKEY" "$KEY_URL"; then
  rm -f "$TMPKEY"
  fail "Bareos key download failed (likely 404). Try: SERIES=xUbuntu_24.04 ./this_script.sh"
fi

info "Installing repo key → $KEYRING"
gpg --dearmor < "$TMPKEY" | tee "$KEYRING" >/dev/null
rm -f "$TMPKEY"

REPO_LINE="deb [signed-by=${KEYRING}] https://download.bareos.org/current/${SERIES}/ /"
info "Writing apt source → $LISTFILE"
echo "$REPO_LINE" > "$LISTFILE"

info "apt update → install Bareos stack"
apt-get update -y
if ! apt-get install -y bareos bareos-database-postgresql bareos-webui; then
  warn "Install failed first pass, attempting 'apt-get -f install' then retry…"
  apt-get -f install -y || true
  apt-get install -y bareos bareos-database-postgresql bareos-webui || fail "Bareos installation failed."
fi
ok "Bareos packages installed"

# ── Initialize Bareos catalog (PostgreSQL) ────────────────────────────────────
if command -v bareos-database-setup >/dev/null 2>&1; then
  info "Initializing Bareos PostgreSQL catalog (idempotent)…"
  bareos-database-setup postgresql || warn "Catalog init returned non-zero (may already exist)."
else
  warn "bareos-database-setup not found; skipping DB init."
fi

# ── Enable services ───────────────────────────────────────────────────────────
info "Enabling and starting Bareos services (dir/sd/fd + webui)…"
systemctl enable --now bareos-dir bareos-sd bareos-fd bareos-webui
ok "Services running. Use: systemctl status bareos-{dir,sd,fd} bareos-webui"

# ── Final summary & tips ──────────────────────────────────────────────────────
echo
ok  "POOL_MODE: ${POOL_MODE}"
ok  "Data pool mount: ${POOL_MNT}"
ok  "Bind → ${BAREOS_STORAGE_DIR}: ${BIND_MOUNT}"
ok  "Bareos repo: ${REPO_LINE}"
ok  "Bareos series: ${SERIES}"
echo
info "Quick checks:"
echo "  - zpool status / zfs list    (if ZFS)   |  lvs/vgs/pvs (if LVM)"
echo "  - df -h $POOL_MNT $BAREOS_STORAGE_DIR"
echo "  - bconsole → 'status storage=FileStorage'"
echo "  - WebUI: http://<server_ip>/bareos-webui/"
echo
info "Next steps:"
echo "  1) Add your tape autochanger (e.g., TL2000) in /etc/bareos/bareos-sd.d/"
echo "  2) Create a small test backup job & restore to verify reads/writes."
echo "  3) Consider snapshots (ZFS) or LV snapshots before tape migration."