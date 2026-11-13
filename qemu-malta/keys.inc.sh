# SPDX-License-Identifier: MIT
# Sourced by the run-*.sh scripts. The guest only accepts keys that were in AUTHORIZED_KEYS at build time.
#   SSH_KEY      private ed25519 key (default ~/.ssh/id_ed25519), required
#   SSH_KEY_RSA  private RSA key (default ~/.ssh/id_rsa), optional: without it the RSA login test is skipped
# The values the overlay was built with must be passed again (LAN_IP, ROUTER_HOSTNAME, WIFI_SSID, WIFI_COUNTRY),
# because the tests check them. Same defaults as ../build/prepare-files.sh.
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
SSH_KEY_RSA=${SSH_KEY_RSA:-$HOME/.ssh/id_rsa}
[ -r "$SSH_KEY" ] || { echo "SSH_KEY $SSH_KEY not readable"; exit 1; }
KEYMOUNTS=(-v "$SSH_KEY:/keys/id_ed25519:ro")
[ -r "$SSH_KEY_RSA" ] && KEYMOUNTS+=(-v "$SSH_KEY_RSA:/keys/id_rsa:ro")
TESTENV=(-e LAN_IP="${LAN_IP:-192.168.1.1}" -e ROUTER_HOSTNAME="${ROUTER_HOSTNAME:-wr740n}"
         -e WIFI_SSID="${WIFI_SSID:-wr740n}" -e WIFI_COUNTRY="${WIFI_COUNTRY:-US}")
