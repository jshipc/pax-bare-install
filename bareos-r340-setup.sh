#!/usr/bin/env bash
# bareos-r340-setup.sh — R340 tailored: ZFS raidz2 on SAS, bind to Bareos storage, install Bareos + WebUI.
set -euo pipefail

### Disks (tailored from your lsblk)
# Using sdb..sdh.  sda had old LVM in your screenshot — add later once cleared.
SAS_DISKS=(/dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf /dev/sdg /dev/sdh)
WIPE_DISKS=false            # change to true ONLY after you confirm data can be destroyed

# ZFS pool/datataset and mount
ZPOOL_NAME="bareospool"
ZFS_LAYOUT="raidz2"         # 7-wide raidz2 = 5 data + 2 parity (good resilience)
ZFS_DATASET="${ZPOOL_NAME}/disk"
POOL_MNT="/srv/bareos-disk"
BAREOS_STORAGE_DIR="/var/lib/bareos/storage"
BIND_MOUNT=true

# Bareos repo series (switch to xUbuntu_25.04 when available)
BAREOS_SERIES="xUbuntu_24.04"

confirm() { read -r -p "$1 [y/N] " ans; [[ "${ans:-}" =~ ^[Yy]$ ]]; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }

echo ">>> Preflight checks"
need lsblk; need awk; mkdir -p "$POOL_MNT"

echo ">>> Verifying disks:"
for d in "${SAS_DISKS[@]}"; do
  [[ -b "$d" ]] || { echo "  !! $d not a block device"; exit 1; }
  echo "  - $d ($(lsblk -dn -o SIZE,MODEL "$d" | awk '{print $1" "$2}'))"
done

if [[ "$WIPE_DISKS" == "true" ]]; then
  need sgdisk; need wipefs
  echo ">>> DANGER: Will wipe: ${SAS_DISKS[*]}"; confirm "Proceed?" || exit 1
  for d in "${SAS_DISKS[@]}"; do sgdisk --zap-all "$d" || true; wipefs -a "$d" || true; done
fi

echo ">>> Installing ZFS utils"
sudo apt-get update -y
sudo apt-get install -y zfsutils-linux

echo ">>> Creating ZFS pool (if absent)"
if ! zpool list "$ZPOOL_NAME" &>/dev/null; then
  zpool create -f "$ZPOOL_NAME" "$ZFS_LAYOUT" "${SAS_DISKS[@]}"
else
  echo "  - zpool $ZPOOL_NAME already exists"
fi

echo ">>> Creating dataset and setting properties"
if ! zfs list "$ZFS_DATASET" &>/dev/null; then
  zfs create -o compression=lz4 -o atime=off -o xattr=sa -o acltype=posixacl -o recordsize=1M "$ZFS_DATASET"
fi
zfs set mountpoint="$POOL_MNT" "$ZFS_DATASET"
zfs mount "$ZFS_DATASET" || true

echo ">>> Preparing Bareos storage path"
mkdir -p "$POOL_MNT" "$BAREOS_STORAGE_DIR"
if [[ "$BIND_MOUNT" == "true" ]]; then
  if ! grep -qE "^[[:space:]]*${POOL_MNT}[[:space:]]+${BAREOS_STORAGE_DIR}[[:space:]]+none[[:space:]]+bind" /etc/fstab; then
    echo "$POOL_MNT  $BAREOS_STORAGE_DIR  none  bind  0 0" >> /etc/fstab
  fi
  mountpoint -q "$BAREOS_STORAGE_DIR" || mount "$BAREOS_STORAGE_DIR"
fi
chown -R bareos:bareos "$BAREOS_STORAGE_DIR" || true

echo ">>> Installing Bareos + PostgreSQL + WebUI"
apt-get install -y curl gnupg apt-transport-https ca-certificates
if [[ ! -f /usr/share/keyrings/bareos.gpg ]]; then
  curl -fsSL "https://download.bareos.org/bareos/release/latest/${BAREOS_SERIES}/Release.key" \
    | gpg --dearmor -o /usr/share/keyrings/bareos.gpg
fi
echo "deb [signed-by=/usr/share/keyrings/bareos.gpg] http://download.bareos.org/bareos/release/latest/${BAREOS_SERIES}/ /" \
  >/etc/apt/sources.list.d/bareos.list
apt-get update -y || true
apt-get install -y bareos bareos-database-postgresql bareos-webui

echo ">>> Initializing Bareos catalog"
bareos-database-setup postgresql || true

echo ">>> Enabling services"
systemctl enable --now bareos-dir bareos-sd bareos-fd bareos-webui
chown -R bareos:bareos "$BAREOS_STORAGE_DIR" || true

echo ">>> Summary"
zpool status "$ZPOOL_NAME" || true
zfs list "$ZFS_DATASET" || true
echo "Storage mounted at: $POOL_MNT  (bind → $BAREOS_STORAGE_DIR)"
echo "WebUI: http://<server_ip>/bareos-webui/  (create a console user in WebUI if needed)"