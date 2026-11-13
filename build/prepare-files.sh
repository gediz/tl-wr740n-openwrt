#!/bin/bash
# SPDX-License-Identifier: MIT
# prepare-files.sh DEST: assemble the image's files overlay in DEST (OpenWrt's "files/" directory).
#
# Copies ../files-bench (first-boot defaults, SSH keys) and, unless NO_WEB=1, ../files-web (the web UI,
# without its README), fills in the @...@ placeholders from the environment and fixes the file modes.
#
# Environment (all optional except a key):
#   LAN_IP           LAN address of the router            default 192.168.1.1
#   ROUTER_HOSTNAME  hostname                              default wr740n
#   WIFI_SSID        SSID of the first-boot AP             default wr740n
#   WIFI_KEY         WPA2 key of the first-boot AP, 8 to 63 letters/digits. Required unless WIFI_OPEN=1.
#                    It ends up in the image: do not share an image built with your key.
#   WIFI_OPEN=1      first-boot AP without encryption, bridged into the LAN (anyone in range reaches the
#                    web UI login and SSH). Only for an isolated bench.
#   WIFI_COUNTRY     ISO country code for the radio        default US (set your own)
#   AUTHORIZED_KEYS  file with your SSH public key(s)      default: ../files-bench/etc/dropbear/authorized_keys
#   NO_WEB=1         leave the web UI out
#   ALLOW_NO_KEY=1   build without any SSH key (you will need failsafe to get in)
#
# The image allows key-only SSH, so without a key you cannot log in. That is why a missing key is an error.
# Every value ends up in the squashfs: longer strings cost bytes, and the final image has only a few KB of margin.
set -eu
DEST=${1:?usage: prepare-files.sh DEST}
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(dirname "$HERE")
: "${LAN_IP:=192.168.1.1}" "${ROUTER_HOSTNAME:=wr740n}" "${WIFI_SSID:=wr740n}" "${WIFI_COUNTRY:=US}"
: "${WIFI_KEY:=}" "${WIFI_OPEN:=0}"
if [ "$WIFI_OPEN" = 1 ]; then
  WIFI_ENC=none; WIFI_PROFILE=open
  echo "prepare-files: WARNING: open first-boot Wi-Fi bridged into the LAN (WIFI_OPEN=1)" >&2
else
  [ -n "$WIFI_KEY" ] || { echo "prepare-files: set WIFI_KEY (8 to 63 letters/digits), or WIFI_OPEN=1 for an open AP" >&2; exit 1; }
  WIFI_ENC=psk2; WIFI_PROFILE=wpa2
fi

ok() { case $2 in *[!$3]*|'') echo "prepare-files: bad $1 '$2'" >&2; exit 1;; esac; }
ok LAN_IP "$LAN_IP" '0-9.'
ok ROUTER_HOSTNAME "$ROUTER_HOSTNAME" 'A-Za-z0-9-'
ok WIFI_SSID "$WIFI_SSID" 'A-Za-z0-9_.-'
ok WIFI_COUNTRY "$WIFI_COUNTRY" 'A-Z0-9'
if [ -n "$WIFI_KEY" ]; then
  ok WIFI_KEY "$WIFI_KEY" 'A-Za-z0-9'
  [ ${#WIFI_KEY} -ge 8 ] && [ ${#WIFI_KEY} -le 63 ] || { echo "prepare-files: WIFI_KEY must be 8 to 63 characters" >&2; exit 1; }
fi

rm -rf "$DEST"
cp -a "$TOP/files-bench" "$DEST"
if [ "${NO_WEB:-0}" != 1 ]; then
  cp -a "$TOP/files-web/." "$DEST/"
  rm -f "$DEST/README.md"
fi
[ -n "${AUTHORIZED_KEYS:-}" ] && cp "$AUTHORIZED_KEYS" "$DEST/etc/dropbear/authorized_keys"
if ! grep -qE '^(ssh-|ecdsa-)' "$DEST/etc/dropbear/authorized_keys"; then
  if [ "${ALLOW_NO_KEY:-0}" = 1 ]; then
    echo "prepare-files: WARNING: no SSH key in the image (ALLOW_NO_KEY=1)" >&2
    rm -f "$DEST/etc/dropbear/authorized_keys"
  else
    echo "prepare-files: no SSH public key. Set AUTHORIZED_KEYS=/path/to/key.pub (see README)." >&2
    exit 1
  fi
fi
grep -rlZ '@[A-Z_]*@' "$DEST" | xargs -0 -r sed -i \
  -e "s/@LAN_IP@/$LAN_IP/g" -e "s/@ROUTER_HOSTNAME@/$ROUTER_HOSTNAME/g" \
  -e "s/@WIFI_SSID@/$WIFI_SSID/g" -e "s/@WIFI_COUNTRY@/$WIFI_COUNTRY/g" \
  -e "s/@WIFI_KEY@/$WIFI_KEY/g" -e "s/@WIFI_ENC@/$WIFI_ENC/g" -e "s/@WIFI_PROFILE@/$WIFI_PROFILE/g"
left=$(grep -rl '@[A-Z_]*@' "$DEST" || true)
[ -z "$left" ] || { echo "prepare-files: unfilled placeholders in: $left" >&2; exit 1; }
# cp -a keeps the host's modes. dropbear ignores authorized_keys when /etc/dropbear is group or
# world writable (a umask 002 host does that), and then a key-only image cannot be entered at all.
chmod -R go-w "$DEST"
chmod 755 "$DEST" "$DEST/etc"
chmod 700 "$DEST/etc/dropbear"
[ -e "$DEST/etc/dropbear/authorized_keys" ] && chmod 600 "$DEST/etc/dropbear/authorized_keys"
echo "prepare-files: $DEST (LAN $LAN_IP, hostname $ROUTER_HOSTNAME, SSID $WIFI_SSID ($WIFI_PROFILE), country $WIFI_COUNTRY, web UI $([ "${NO_WEB:-0}" = 1 ] && echo no || echo yes))"
