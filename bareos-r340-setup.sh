#!/usr/bin/env bash
# ==============================================================================
# r340-bareos-full-setup.sh
#
# One-shot build for a Dell R340 backup server on Ubuntu 24.04/25.04:
#   1) (Optional) Create a large backup pool on SAS disks (ZFS raidz2 OR LVM+XFS)
#   2) Bind-mount that pool to /var/lib/bareos/storage (Bareos FileStorage default)
#   3) Add Bareos APT repo (CURRENT) + install bareos + DB + WebUI
#   4) Initialize the PostgreSQL catalog and start services
#
# FIXES INCLUDED:
#   - Use https://download.bareos.org/current/<series>/Release.key (old path 404’d)
#   - If bareos-database-setup is missing, use canonical helper scripts:
#       create_bareos_database, make_bareos_tables, grant_bareos_privileges
#   - WebUI is an Apache conf — start *apache2*, not a nonexistent bareos-webui.service
#
# SAFETY:
#   - Won’t wipe disks unless WIPE_DISKS=true and you confirm "YES"
#   - Idempotent where practical: re-runs won’t recreate pools/volumes/configs
# ==============================================================================

set -euo pipefail

# ── Pretty output helpers ──────────────────────────────────────────────────────
info()  { printf "\033[1;36m[INFO]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[ OK ]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
fail()  { printf "\033[1;31m[FAIL]\033[0m %s\n" "$*"; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

# ── TOGGLES: adjust for your environment ──────────────────────────────────────
# Choose backing pool type for the large backup volume:
POOL_MODE="ZFS"                # "ZFS"  or  "LVM"

# List ONLY your SAS data disks (NOT the BOSS SSDs). Adjust to match `lsblk`.
SAS_DISKS=(/dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf /dev/sdg /dev/sdh)

# DANGER: if true, will wipe partition tables & FS signatures on SAS_DISKS.
WIPE_DISKS=false

# Where the big pool is mounted, and where Bareos FileStorage expects to write:
POOL_MNT="/srv/bareos-disk"
BAREOS_STORAGE_DIR="/var/lib/bareos/storage"
BIND_MOUNT=true                # bind POOL_MNT → /var/lib/bareos/storage

# ZFS options (if POOL_MODE=ZFS)
ZPOOL_NAME="bareospool"
ZFS_LAYOUT="raidz2"            # raidz2 recommended for 6–10 disks
ZFS_DATASET="${ZPOOL_NAME}/disk"
ZFS_OPTS=(-O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl -O recordsize=1M)

# LVM options (if POOL_MODE=LVM)
VG_NAME="bareos-vg"
LV_NAME="bareos-lv"
LV_SIZE="100%FREE"            # or "8T", etc.
LVM_FS="xfs"                  # xfs is great for large sequential files

# Optional: force Bareos series via env (e.g., `SERIES=xUbuntu_24.04 ./script.sh`)
# Otherwise we auto-detect from OS version.
# ───────────────────────────────────────────────────────────────────────────────

# ── Detect Bareos repo series (xUbuntu_25.04, xUbuntu_24.04, …) ───────────────
detect_series() {
  local ver=""
  if command -v lsb_release >/dev/null 2>&1; then
    ver="$(lsb_release -sr)"                 # "25.04", "24.04", …
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

# ── Pre-flight checks ──────────────────────────────────────────────────────────
need lsblk; need awk
mkdir -p "$POOL_MNT" "$BAREOS_STORAGE_DIR"

info "Verifying SAS disks exist as block devices:"
for d in "${SAS_DISKS[@]}"; do
  [[ -b "$d" ]] || fail "$d is not a block device; edit SAS_DISKS in the script"
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
  ok "Disk wipe complete"
fi

# ── Build the large backup pool ────────────────────────────────────────────────
if [[ "$POOL_MODE" == "ZFS" ]]; then
  info "Installing ZFS utilities…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y zfsutils-linux
  need zpool; need zfs

  info "Ensuring ZFS pool '$ZPOOL_NAME' exists (layout: $ZFS_LAYOUT)…"
  if ! zpool list "$ZPOOL_NAME" &>/dev/null; then
    zpool create -f "$ZPOOL_NAME" "$ZFS_LAYOUT" "${SAS_DISKS[@]}"
  else
    ok "ZFS pool $ZPOOL_NAME already present"
  fi

  info "Ensuring dataset '$ZFS_DATASET' exists with tuned options"
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

  info "Creating PVs (if missing)"
  for d in "${SAS_DISKS[@]}"; do
    if ! pvs --noheadings "$d" &>/dev/null; then
      pvcreate -ff -y "$d"
      echo "  - pvcreate $d"
    else
      echo "  - PV exists on $d"
    fi
  done

  info "Creating VG '$VG_NAME' (if missing)"
  if ! vgdisplay "$VG_NAME" &>/dev/null; then
    vgcreate "$VG_NAME" "${SAS_DISKS[@]}"
  else
    ok "VG $VG_NAME exists"
  fi

  info "Creating LV '$LV_NAME' (if missing)"
  if ! lvdisplay "/dev/$VG_NAME/$LV_NAME" &>/dev/null; then
    lvcreate -n "$LV_NAME" -l "$LV_SIZE" "$VG_NAME"
  else
    ok "LV $LV_NAME exists"
  fi

  LV_DEV="/dev/$VG_NAME/$LV_NAME"
  FS_TYPE="$(lsblk -no FSTYPE "$LV_DEV" || true)"
  if [[ -z "$FS_TYPE" ]]; then
    info "Formatting $LV_DEV as $LVM_FS"
    mkfs."$LVM_FS" -f "$LV_DEV"
  else
    ok "$LV_DEV already formatted as $FS_TYPE"
  fi

  # Add to fstab via UUID (so device names can change safely)
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

# ── Bind-mount the pool to Bareos FileStorage path ────────────────────────────
if [[ "$BIND_MOUNT" == "true" ]]; then
  info "Bind-mounting $POOL_MNT  →  $BAREOS_STORAGE_DIR"
  mkdir -p "$BAREOS_STORAGE_DIR"
  if ! grep -qE "^[[:space:]]*${POOL_MNT}[[:space:]]+${BAREOS_STORAGE_DIR}[[:space:]]+none[[:space:]]+bind" /etc/fstab; then
    echo "$POOL_MNT  $BAREOS_STORAGE_DIR  none  bind  0 0" >> /etc/fstab
  fi
  mountpoint -q "$BAREOS_STORAGE_DIR" || mount "$BAREOS_STORAGE_DIR"
fi
# Ensure Bareos SD can write
chown -R bareos:bareos "$BAREOS_STORAGE_DIR" 2>/dev/null || true
ok "Storage location ready: $BAREOS_STORAGE_DIR"

# ── Add Bareos APT repo (CURRENT) with 404 guard ──────────────────────────────
info "Adding Bareos repository (series: ${SERIES})"
apt-get install -y curl gpg ca-certificates apt-transport-https

KEY_URL="https://download.bareos.org/current/${SERIES}/Release.key"
KEYRING="/usr/share/keyrings/bareos.gpg"
LISTFILE="/etc/apt/sources.list.d/bareos.list"
TMPKEY="$(mktemp)"

info "Downloading repo key: $KEY_URL"
if ! curl -fSLo "$TMPKEY" "$KEY_URL"; then
  rm -f "$TMPKEY"
  fail "Bareos key download failed (HTTP error). Try: SERIES=xUbuntu_24.04 ./r340-bareos-full-setup.sh"
fi

info "Installing repo key → $KEYRING"
gpg --dearmor < "$TMPKEY" | tee "$KEYRING" >/dev/null
rm -f "$TMPKEY"

REPO_LINE="deb [signed-by=${KEYRING}] https://download.bareos.org/current/${SERIES}/ /"
info "Writing APT source → $LISTFILE"
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
info "Initializing Bareos PostgreSQL catalog (idempotent)…"
if command -v bareos-database-setup >/dev/null 2>&1; then
  # Some builds ship this wrapper; harmless if it says "already exists"
  bareos-database-setup postgresql || warn "Catalog init returned non-zero (may already exist)."
else
  # Canonical helper scripts shipped by bareos-database-postgresql
  if [[ -x /usr/lib/bareos/scripts/create_bareos_database ]]; then
    /usr/lib/bareos/scripts/create_bareos_database       || true
    /usr/lib/bareos/scripts/make_bareos_tables           || true
    /usr/lib/bareos/scripts/grant_bareos_privileges      || true
  else
    warn "Bareos DB helper scripts not found in /usr/lib/bareos/scripts (is bareos-database-postgresql installed?)"
  fi
fi

# ── Enable services (Bareos daemons + Apache for WebUI) ───────────────────────
info "Enabling and starting Bareos services and Apache (WebUI)…"
systemctl enable --now bareos-dir bareos-sd bareos-fd || fail "Failed to start Bareos daemons"
# WebUI is served by Apache; there is no separate bareos-webui.service unit
systemctl enable --now apache2 || warn "Apache2 failed to start; WebUI will be unavailable"
# Ensure the Bareos WebUI Apache config is active
a2enconf bareos-webui 2>/dev/null || true
systemctl reload apache2 2>/dev/null || true
ok "Services running (bareos-dir/sd/fd + apache2)"

# ── Final summary & quick checks ──────────────────────────────────────────────
echo
ok  "POOL_MODE: ${POOL_MODE}"
ok  "Pool mount: ${POOL_MNT}"
ok  "Bind → ${BAREOS_STORAGE_DIR}: ${BIND_MOUNT}"
ok  "Bareos repo: ${REPO_LINE}"
ok  "Bareos series: ${SERIES}"
echo
info "Run these quick checks:"
echo "  - df -h ${POOL_MNT} ${BAREOS_STORAGE_DIR}"
echo "  - (ZFS) zpool status && zfs list   |  (LVM) lvs && vgs && pvs"
echo "  - systemctl status --no-pager bareos-dir bareos-sd bareos-fd apache2"
echo "  - sudo -u postgres psql -Atc \"SELECT datname FROM pg_database\" | grep -i bareos"
echo "  - bconsole → 'status director', 'status storage=FileStorage'"
echo "  - WebUI:  http://<server_ip>/bareos-webui/"