#!/usr/bin/env bash
# ==============================================================================
# r340-bareos-full-setup.sh
#
# Turnkey build for a Dell R340 Bareos server on Ubuntu 24.04 / 25.04:
#   1) (Optional) Create a large backup pool on SAS disks
#        - ZFS raidz2  OR  LVM + XFS   (choose below)
#   2) Bind-mount the pool to /var/lib/bareos/storage  (Bareos FileStorage)
#   3) Add Bareos APT repo (CURRENT), install bareos + DB + WebUI
#   4) Install & start PostgreSQL
#   5) Create/validate the Bareos catalog, **forcing UTF-8** (works even if the
#      cluster is SQL_ASCII by recreating DB from template0 with explicit locale)
#   6) Start Bareos daemons (correct unit names) + Apache for WebUI
#
# Key fixes baked-in:
#   - Correct Bareos repo URL (https://download.bareos.org/current/<series>)
#   - 404 guard on key download (clear error if the series isn’t published yet)
#   - Use real systemd units: bareos-director / bareos-storage / bareos-filedaemon
#   - Run DB scripts as postgres; if DB not UTF-8, drop & recreate with UTF-8
#   - WebUI rides on apache2 (no "bareos-webui.service")
# ==============================================================================

set -euo pipefail

# ────────────────────────── Pretty output helpers ──────────────────────────────
info()  { printf "\033[1;36m[INFO]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[ OK ]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
fail()  { printf "\033[1;31m[FAIL]\033[0m %s\n" "$*"; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

# ────────────────────────────────── TOGGLES ────────────────────────────────────
POOL_MODE="ZFS"   # "ZFS" or "LVM"

# List your SAS data disks ONLY (not the BOSS SSDs). Adjust via `lsblk`.
SAS_DISKS=(/dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf /dev/sdg /dev/sdh)

WIPE_DISKS=false  # DANGER: true erases partition tables & signatures on SAS_DISKS

# Mount points
POOL_MNT="/srv/bareos-disk"
BAREOS_STORAGE_DIR="/var/lib/bareos/storage"
BIND_MOUNT=true   # bind POOL_MNT → BAREOS_STORAGE_DIR

# ZFS options (if POOL_MODE="ZFS")
ZPOOL_NAME="bareospool"
ZFS_LAYOUT="raidz2"
ZFS_DATASET="${ZPOOL_NAME}/disk"
ZFS_OPTS=(-O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl -O recordsize=1M)

# LVM options (if POOL_MODE="LVM")
VG_NAME="bareos-vg"
LV_NAME="bareos-lv"
LV_SIZE="100%FREE"
LVM_FS="xfs"

# Bareos catalog DB name (PostgreSQL)
BAREOS_DB_NAME="bareos"

# Optional: override Bareos repo series (auto-detected if unset)
# export SERIES=xUbuntu_24.04

# ─────────────────────────── helpers for PostgreSQL ───────────────────────────
psql_su()      { sudo -u postgres psql "$@"; }
psql_quiet_ok(){ psql_su -Atc "$1" >/dev/null 2>&1; }

# Detect Ubuntu → Bareos series (xUbuntu_25.04, xUbuntu_24.04, …)
detect_series() {
  local v=""
  if command -v lsb_release >/dev/null 2>&1; then
    v="$(lsb_release -sr)"
  elif [[ -f /etc/os-release ]]; then
    v="$(. /etc/os-release; echo "${VERSION_ID:-}")"
  fi
  case "$v" in
    25.04) echo "xUbuntu_25.04" ;;
    24.04) echo "xUbuntu_24.04" ;;
    22.04) echo "xUbuntu_22.04" ;;
    *)     warn "Unknown Ubuntu VERSION_ID '$v'; defaulting to xUbuntu_24.04"; echo "xUbuntu_24.04" ;;
  esac
}

SERIES="${SERIES:-$(detect_series)}"
info "Using Bareos repository series: ${SERIES}"

# ───────────────────────────────── Pre-flight ─────────────────────────────────
need lsblk; need awk
mkdir -p "$POOL_MNT" "$BAREOS_STORAGE_DIR"

info "Verifying SAS disks:"
for d in "${SAS_DISKS[@]}"; do
  [[ -b "$d" ]] || fail "$d is not a block device; edit SAS_DISKS"
  echo "  - $d ($(lsblk -dn -o SIZE,MODEL "$d" | awk '{print $1" "$2}'))"
done

if [[ "$WIPE_DISKS" == "true" ]]; then
  need sgdisk; need wipefs
  warn "WIPE_DISKS=true → ERASES: ${SAS_DISKS[*]}"
  read -r -p "Type YES to continue: " x; [[ "$x" == "YES" ]] || fail "Aborted."
  for d in "${SAS_DISKS[@]}"; do sgdisk --zap-all "$d" || true; wipefs -a "$d" || true; done
  ok "Disk wipe complete"
fi

# ───────────────────────────── Build the pool ─────────────────────────────────
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

  info "Creating PVs if needed…"
  for d in "${SAS_DISKS[@]}"; do
    pvs --noheadings "$d" &>/dev/null || { pvcreate -ff -y "$d"; echo "  - pvcreate $d"; }
  done

  info "Creating VG '$VG_NAME' if needed…"
  vgdisplay "$VG_NAME" &>/dev/null || vgcreate "$VG_NAME" "${SAS_DISKS[@]}"

  info "Creating LV '$LV_NAME' if needed…"
  lvdisplay "/dev/$VG_NAME/$LV_NAME" &>/dev/null || lvcreate -n "$LV_NAME" -l "$LV_SIZE" "$VG_NAME"

  LV_DEV="/dev/$VG_NAME/$LV_NAME"
  FS_TYPE="$(lsblk -no FSTYPE "$LV_DEV" || true)"
  [[ -n "$FS_TYPE" ]] || mkfs."$LVM_FS" -f "$LV_DEV"

  UUID=$(blkid -s UUID -o value "$LV_DEV")
  grep -q "$UUID" /etc/fstab || echo "UUID=$UUID  $POOL_MNT  $LVM_FS  noatime,nodiratime  0 2" >> /etc/fstab
  mountpoint -q "$POOL_MNT" || mount "$POOL_MNT"
  ok "LVM volume mounted at $POOL_MNT"

else
  fail "POOL_MODE must be 'ZFS' or 'LVM'"
fi

# Bind-mount to Bareos storage
if [[ "$BIND_MOUNT" == "true" ]]; then
  info "Bind-mounting: $POOL_MNT  →  $BAREOS_STORAGE_DIR"
  mkdir -p "$BAREOS_STORAGE_DIR"
  grep -qE "^\s*${POOL_MNT}\s+${BAREOS_STORAGE_DIR}\s+none\s+bind" /etc/fstab \
    || echo "$POOL_MNT  $BAREOS_STORAGE_DIR  none  bind  0 0" >> /etc/fstab
  mountpoint -q "$BAREOS_STORAGE_DIR" || mount "$BAREOS_STORAGE_DIR"
fi
# Ensure the SD can write here
chown -R bareos:bareos "$BAREOS_STORAGE_DIR" 2>/dev/null || true
ok "Storage path ready: $BAREOS_STORAGE_DIR"

# ─────────────────────────── Add Bareos APT repo ──────────────────────────────
info "Adding Bareos repo (series: ${SERIES})"
apt-get install -y curl gpg ca-certificates apt-transport-https
KEY_URL="https://download.bareos.org/current/${SERIES}/Release.key"
KEYRING="/usr/share/keyrings/bareos.gpg"
LISTFILE="/etc/apt/sources.list.d/bareos.list"
TMPKEY="$(mktemp)"

info "Fetching key: $KEY_URL"
if ! curl -fSLo "$TMPKEY" "$KEY_URL"; then
  rm -f "$TMPKEY"
  fail "Bareos key download failed; try SERIES=xUbuntu_24.04"
fi
gpg --dearmor < "$TMPKEY" | tee "$KEYRING" >/dev/null
rm -f "$TMPKEY"

echo "deb [signed-by=${KEYRING}] https://download.bareos.org/current/${SERIES}/ /" > "$LISTFILE"
apt-get update -y
apt-get install -y bareos bareos-database-postgresql bareos-webui \
  || { apt-get -f install -y || true; apt-get install -y bareos bareos-database-postgresql bareos-webui; }
ok "Bareos packages installed"

# ───────────── Ensure PostgreSQL is installed, enabled, and responsive ────────
info "Ensuring PostgreSQL is installed and running…"
apt-get install -y postgresql
systemctl enable --now postgresql
psql_quiet_ok "SELECT 1" || fail "PostgreSQL not responding on local socket"

# Optional: show cluster-wide encoding (diagnostic only)
psql_su -Atc "SHOW server_encoding;" || true

# ────────── Force a UTF-8 Bareos database (works even if cluster is SQL_ASCII) ──────────
ensure_locale() {
  # Make sure the desired UTF-8 locale exists on the OS
  locale -a | grep -qi '^en_US\.utf8$' || sudo locale-gen en_US.UTF-8
}
db_role_exists() {
  sudo -u postgres psql -Atc "SELECT 1 FROM pg_roles WHERE rolname='bareos';" 2>/dev/null | grep -q 1
}
db_exists() {
  sudo -u postgres psql -Atc "SELECT 1 FROM pg_database WHERE datname='bareos';" 2>/dev/null | grep -q 1
}
db_is_utf8() {
  sudo -u postgres psql -Atc \
  "SELECT (pg_encoding_to_char(encoding)='UTF8')::int FROM pg_database WHERE datname='bareos';" 2>/dev/null | grep -q '^1$'
}

info "Ensuring Bareos database exists and is UTF-8…"
ensure_locale
db_role_exists || sudo -u postgres createuser -DRS bareos

if db_exists; then
  if db_is_utf8; then
    ok "Bareos DB already UTF-8"
  else
    warn "Bareos DB is not UTF-8; recreating with UTF-8…"
    # Stop Director to avoid locks (ignore if not running)
    systemctl stop bareos-director 2>/dev/null || true
    # Try to disconnect sessions cleanly (ignore errors)
    sudo -u postgres psql -c "REVOKE CONNECT ON DATABASE bareos FROM PUBLIC;" 2>/dev/null || true
    sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='bareos';" 2>/dev/null || true
    # Drop and recreate from template0 with explicit encoding + locale
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS bareos;"
    sudo -u postgres createdb -O bareos -E UTF8 \
      --lc-collate='en_US.UTF-8' --lc-ctype='en_US.UTF-8' \
      -T template0 bareos
    ok "Recreated Bareos DB with UTF-8"
  fi
else
  info "Creating Bareos DB with UTF-8…"
  sudo -u postgres createdb -O bareos -E UTF8 \
    --lc-collate='en_US.UTF-8' --lc-ctype='en_US.UTF-8' \
    -T template0 bareos
fi

# Load schema/grants (idempotent and safe to run multiple times)
sudo -u postgres /usr/lib/bareos/scripts/make_bareos_tables       || true
sudo -u postgres /usr/lib/bareos/scripts/grant_bareos_privileges  || true

# ─────────────── Start Bareos daemons (correct units) + Apache ────────────────
info "Starting Bareos daemons and Apache (WebUI)…"
systemctl enable --now bareos-director bareos-storage bareos-filedaemon \
  || fail "Failed to start Bareos daemons (director/storage/filedaemon)"
systemctl enable --now apache2 || warn "Apache2 failed to start; WebUI unavailable"
a2enconf bareos-webui 2>/dev/null || true
systemctl reload apache2 2>/dev/null || true
ok "Services running"

# ─────────────────────────── Final checks / tips ───────────────────────────────
echo
ok  "POOL_MODE: ${POOL_MODE}"
ok  "Pool mount: ${POOL_MNT}  →  ${BAREOS_STORAGE_DIR} (bind: ${BIND_MOUNT})"
ok  "Repo series: ${SERIES}"
echo
info "Quick checks:"
echo "  - df -h ${POOL_MNT} ${BAREOS_STORAGE_DIR}"
echo "  - (ZFS) zpool status && zfs list   |  (LVM) lvs && vgs && pvs"
echo "  - systemctl status --no-pager bareos-director bareos-storage bareos-filedaemon apache2"
echo "  - sudo -u postgres psql -c \"SELECT datname, pg_encoding_to_char(encoding) AS enc, datcollate, datctype FROM pg_database WHERE datname='bareos';\""
echo "  - WebUI:  http://<server_ip>/bareos-webui/"