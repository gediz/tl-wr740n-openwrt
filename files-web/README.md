<!-- SPDX-License-Identifier: MIT -->
# benchweb: web UI and HTTP API without LuCI

A small web page and JSON API for the TL-WR740N bench router. The server is busybox httpd; everything else is POSIX sh CGI scripts that call uci, wifi, tc, swconfig, mdio, sysupgrade, logread, iw, ping and firstboot. No LuCI, uhttpd, rpcd or Lua.

This directory is a files overlay, like ../files-bench. `../build/prepare-files.sh` copies it on top of files-bench (leave it out with `NO_WEB=1`) and fills in `@WIFI_SSID@`. This README is not part of the overlay: the script deletes it after copying.

## What is in the overlay

| Path | Content |
|---|---|
| /etc/init.d/benchweb | procd service: `httpd -f -p <lan ip>:80 -h /www-bench -c /etc/benchweb/httpd.conf`, started with oom_score_adj 1000 |
| /etc/uci-defaults/90-benchweb | first boot: creates /etc/benchweb (mode 700) with password, httpd.conf, wifi.conf, web.conf (all 600). Existing files are kept |
| /lib/upgrade/keep.d/benchweb | keeps /etc/benchweb/, /etc/config/ and /etc/dropbear/ in backups and over sysupgrade |
| /usr/lib/benchweb.sh | shared helpers (client, Host and Origin checks, input checks, JSON, locking, timers) |
| /www-bench/index.html | the page |
| /www-bench/cgi-bin/* | status, wifi, netem, port, dhcp, log, leases, clients, ping, backup, restore, upgrade, reset, reboot |

Size: scripts and init files 17,827 bytes, page 3,207 bytes, uncompressed. The overlay is part of the final TL-WR740N image (../build). There, busybox httpd with these features, this overlay and the Wi-Fi lines in ../files-bench/etc/uci-defaults/99-bench together cost 12,736 bytes of rootfs. See ../docs/size-budget.md.

The busybox config needs: `CONFIG_BUSYBOX_CONFIG_HTTPD`, `..._FEATURE_HTTPD_BASIC_AUTH`, `..._FEATURE_HTTPD_AUTH_MD5`, `..._FEATURE_HTTPD_CGI` (all `=y`).

## Access and auth

The server listens on the LAN address (`network.lan.ipaddr`, port 80). That alone is not a boundary: there is no firewall on this image, and with the kernel's weak host model a host on the WAN side that routes the LAN address via the router's WAN address reaches it too. Wi-Fi clients are bridged into the LAN; with the `open` profile that is anyone in radio range.

Before anything else, every CGI checks the request and answers 403 otherwise:

- the client address (`REMOTE_ADDR`) is in the LAN subnet (`network.lan.ipaddr` and `netmask`);
- `Host` is empty or the LAN address (with or without `:80`), which blocks DNS rebinding;
- `Origin` is empty or `http://<LAN address>`. Browsers send Origin on every cross-site POST, so a page on another site cannot use the cached login to post here (CSRF). curl sends no Origin.

The static page (/, index.html) is still served to any client with the password; it holds no data. CGI replies carry `X-Frame-Options: SAMEORIGIN` and the page blanks itself when framed by another site.

httpd has no connection limit. It runs with oom_score_adj 1000, so when a flood of connections (no password needed) uses up memory, the kernel kills httpd and its children first; procd restarts httpd. System daemons keep running. Reboot, sysupgrade and netem timers started by the CGIs go back to oom_score_adj 0.

There is no TLS: credentials travel base64-encoded, and on the `open` Wi-Fi profile they can be sniffed. Use it only on the bench network.

Every URL, including the page, needs HTTP basic auth. User `bench`, password generated at first boot (24 hex characters). Read it over SSH:

```
ssh root@$LAN_IP cat /etc/benchweb/password
```

/etc/benchweb/httpd.conf holds the MD5-crypt hash (`/:bench:$1$...`), not the password. To change the password:

```
ssh root@$LAN_IP 'umask 077; echo NEWPASS > /etc/benchweb/password; printf "/:bench:%s\n" "$(httpd -m NEWPASS)" > /etc/benchweb/httpd.conf'
```

httpd reads the file per request, no restart needed.

Why basic auth and not a bearer token: busybox httpd checks basic auth itself, before any CGI runs, for static files and CGIs alike, and browsers support it without JavaScript. A bearer token would have to be checked in every script (busybox passes a non-Basic `Authorization` header to CGIs as `HTTP_AUTHORIZATION`, but not to static files), and the page would need JavaScript to send it. Only one scheme is implemented.

## Input rules

- GET reads, POST changes. Wrong method: 405.
- Parameters come from the query string or an `application/x-www-form-urlencoded` body of at most 512 bytes. The whole parameter string may only contain `A-Z a-z 0-9 _ . = & -`. Anything else, including `%` escapes, spaces, `;`, `$`, backticks and newlines, gets 400 before any parameter is looked at.
- Each value is then checked against a fixed list or a number range. Nothing from the request is passed to eval or used unquoted in a command.
- Uploads (restore, upgrade) are raw bodies with `Content-Type: application/octet-stream`; anything else gets 400. A cross-site page cannot send that type without a CORS preflight, which httpd does not answer.
- Changes take a lock (/tmp/benchweb.lock); a second change waits up to 20 s, then gets 409. An upload that stalls gives up after `upload_timeout_s` (default 300 s) and frees the lock.
- Each change is logged: `logread | grep benchweb`.

Reads (status, log, leases, clients, ping) are not locked and, except ping, not logged.

Errors are JSON: `{"error":"..."}` with status 400, 403, 405, 409, 500, 503 or 507.

Settings in /etc/benchweb/web.conf (`key=value`, all optional):

| Key | Default | Meaning |
|---|---|---|
| min_mem_kb | 6144 | refuse a firmware upload (507) below this MemAvailable |
| upload_timeout_s | 300 | give up on an upload body after this many seconds |
| image_keep_s | 600 | delete a tested, unflashed image from /tmp after this many seconds |
| mdio_bus, port_phys | `*:1f`, `0 1 2 3` | port control, see /cgi-bin/port |

## Endpoints

Below, `A='-u bench:PASSWORD'` and `R=http://$LAN_IP` (192.168.1.1 unless you built with another `LAN_IP`).

### GET /cgi-bin/status

```
curl $A $R/cgi-bin/status
{"uptime":40,"load":[0.10,0.03,0.01],"mem_kb":{"total":21528,"available":6068},
 "firmware":"OpenWrt 24.10.8 r29233-443ec4032a","kernel":"6.6.144","lan_ip":"192.168.1.1",
 "ports":{"1":"link:up speed:100baseT full-duplex auto",...},
 "wifi":{"profile":"wpa2","up":true,"ifname":"phy0-ap0","ssid":"wr740n","channel":"6","encryption":"WPA2 PSK (CCMP)","clients":1},
 "netem":{"lan":[{"dev":"eth1","netem":"delay 100ms loss 10%"}],"wan":[{"dev":"eth0","netem":""}],"wlan":[]}}
```

`ports` is null when there is no switch. `netem` is empty when the device has no netem qdisc.

### GET, POST /cgi-bin/wifi

```
curl $A $R/cgi-bin/wifi
curl $A -d 'profile=wpa3&channel=6' $R/cgi-bin/wifi
```

`profile`: `off`, `open`, `wpa2` (psk2), `wpa3` (sae, PMF required), `mixed` (sae-mixed, PMF optional), `ft-psk`, `ft-sae` (802.11r), `owe`. `channel`: 1 to 13, optional (unchanged if left out; set to 1 if the radio says `auto`, since ACS is not built).

The script replaces the uci section `wireless.bench` on the radio, disables any other wifi-iface on that radio, commits and runs `wifi reload`. GET reports the profile stored in /etc/benchweb/profile. 99-bench puts the first-boot AP in `wireless.bench` and writes `open` there, so GET shows `open` from the first boot. On a keep-settings upgrade from a config that has the AP in `wireless.default_radio0`, 99-bench renames that section to `bench` and writes the profile, unless a `bench` section already exists. Profile `off` deletes `bench`, so it is not kept: after a keep-settings upgrade the radio comes back on with the open AP and profile `open`. Apply `off` again after the upgrade if it is wanted. SSID, key and mobility domain come from /etc/benchweb/wifi.conf (created at first boot with a random 16 hex character key; edit it over SSH, then apply a profile again). The key is not shown by the API.

### GET, POST /cgi-bin/netem

```
curl $A $R/cgi-bin/netem
curl $A -d 'iface=lan&delay_ms=100&loss_pct=10' $R/cgi-bin/netem
curl $A -d 'iface=lan&delay_ms=300&for_s=60' $R/cgi-bin/netem     # removed again after 60 s
curl $A -d 'iface=lan&action=clear' $R/cgi-bin/netem
```

`iface`: `lan` (wired members of br-lan), `wan` (`network.wan.device`), `wlan` (Wi-Fi members of br-lan; 409 when the AP is down). `delay_ms` 0 to 5000, `loss_pct` 0 to 100, `for_s` 1 to 86400 (optional auto-clear). Runs `tc qdisc replace dev X root netem delay Nms loss N%` or `tc qdisc del dev X root`.

Each interface has its own auto-clear timer. A new set or clear on the same interface cancels it; changes on other interfaces leave it alone. The timer does not hold the lock while it waits.

Careful: netem on `lan` also delays and drops your own web and SSH traffic. Use `for_s` for anything that could lock you out (for example `loss_pct=100`).

### GET, POST /cgi-bin/port

```
curl $A $R/cgi-bin/port
curl $A -d 'port=2&action=down' $R/cgi-bin/port
```

`port` 1 to 4, `action` `up` or `down`. GET shows `swconfig dev switch0 port N get link`. POST sets or clears BMCR bit 11 (power down) on the port's PHY with mdio-tools; `up` also restarts autonegotiation. Returns 503 `{"error":"no switch"}` when swconfig finds no switch (as in QEMU) and 503 with the mdio message when the bus or PHY is not found.

Not tested on the router. Defaults: MDIO bus glob `*:1f` (the ar7240sw switch's own bus, named after its MDIO device at address 0x1f) and PHY addresses `0 1 2 3` for ports 1 to 4. If the port labels or bus name differ, set `mdio_bus=` and `port_phys=` in /etc/benchweb/web.conf (`mdio` with no arguments lists the buses).

### GET, POST /cgi-bin/dhcp

```
curl $A -d action=off $R/cgi-bin/dhcp     # sets dhcp.lan.ignore=1, reloads dnsmasq
curl $A -d action=on  $R/cgi-bin/dhcp
```

DNS keeps working when DHCP is off.

### GET /cgi-bin/log

```
curl $A "$R/cgi-bin/log?n=50"
["Wed Nov 11 10:55:57 2026 kern.notice kernel: Linux version 6.6.144 ...",
 "Wed Nov 11 10:59:52 2026 user.notice benchweb: bench@192.168.1.2 dhcp action=on", ...]
```

The last `n` lines of `logread` (system and kernel messages), oldest first, as a JSON array of strings. `n` 10 to 500, default 100. Control characters and non-ASCII bytes are dropped; `"` and `\` are escaped.

### GET /cgi-bin/leases

```
curl $A $R/cgi-bin/leases
[{"expiry":1794437958,"mac":"02:00:00:00:00:10","ip":"192.168.1.223","hostname":"laptop"}]
```

DHCP leases from /tmp/dhcp.leases (dnsmasq). `expiry` is Unix time. `hostname` is empty when the client sent none. Each field is cut to its allowed characters.

### GET /cgi-bin/clients

```
curl $A $R/cgi-bin/clients
{"phy0-ap0":[{"mac":"02:00:00:00:01:00","signal_dbm":-30,"rx_mbit":54,"tx_mbit":1,"connected_s":92}]}
```

Associated stations per AP interface, from `iw dev <if> station dump`. `iw` is used instead of `iwinfo assoclist` or hostapd's ubus `get_clients` because only `iw` reports the connected time. `rx_mbit` and `tx_mbit` are the last bitrates and are null until the station has sent or received data. `{}` when no AP is up.

### POST /cgi-bin/ping

```
curl $A -d 'host=192.168.1.20&count=3' $R/cgi-bin/ping
{"host":"192.168.1.20","count":3,"transmitted":3,"received":3,"loss_pct":0,"rtt_ms":{"min":0.400,"avg":0.657,"max":1.150}}
```

Runs `ping -q -c COUNT -w COUNT+3 HOST` and returns the summary. `host`: an IPv4 dotted quad (each part 0 to 255) or a host name of 1 to 63 characters from `A-Z a-z 0-9 . -`, not starting with `-` or `.`. `count` 1 to 10, default 3. Nothing else reaches ping. `rtt_ms` is null when no reply came back. A name that does not resolve gets 400 with ping's message. Logged.

### POST /cgi-bin/reset

```
curl $A -d confirm=yes $R/cgi-bin/reset
{"ok":true,"resetting":true}
```

Factory reset. Needs `confirm=yes` (anything else: 400) and passes the same client, Host and Origin checks as every other CGI. Takes the lock, logs, replies, then 2 s later runs `firstboot -y && reboot`. firstboot deletes every file in the overlay (the writable part of the flash); the read-only image is not touched. At the next boot the first-boot scripts run again: 99-bench sets the LAN address, key-only SSH (authorized_keys is in the image) and the open bench Wi-Fi on channel 1 (section `wireless.bench`, profile `open`), and 90-benchweb makes a new web password, Wi-Fi key and web.conf. The SSH host keys are new too, so SSH clients warn about a changed host key. Everything set over SSH or the API since the last flash is lost, including logs.

### GET /cgi-bin/backup

```
curl $A -o backup.tar.gz $R/cgi-bin/backup
```

Streams `sysupgrade -b -` as application/gzip (about 5 KB). Contains every changed file sysupgrade keeps: /etc/config/*, /etc/benchweb/* (web password and Wi-Fi key), /etc/dropbear/* (host keys and authorized_keys), /etc/passwd, /etc/shadow, /etc/group, /etc/inittab, /etc/rc.local, /etc/profile and a few more. Treat it as a secret. A page on another site cannot read it (no CORS).

### POST /cgi-bin/restore

```
curl $A -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @backup.tar.gz $R/cgi-bin/restore
```

Raw tar.gz body, at most 262,144 bytes. Saved to /tmp and checked with `tar -tzf` and `tar -tvzf`: every member must be a regular file or directory under `etc/`, with no `..` component; symlinks, hard links and device files are refused (400), and so is anything tar warns about. Then restored with `sysupgrade -r`, and the router reboots 2 s after the reply.

Restore is root access by design: a file such as etc/rc.local or etc/uci-defaults/* runs as root at the next boot. The checks keep files inside /etc, nothing more. If extraction fails part way (for example the overlay is full) the reply is 500, no reboot happens, and the files written so far stay: restore a good backup again, or fix it over SSH.

### POST /cgi-bin/upgrade

Two steps.

```
curl $A -H 'Expect:' -H 'Content-Type: application/octet-stream' --data-binary @openwrt-...-sysupgrade.bin $R/cgi-bin/upgrade
{"ok":true,"test":"passed","size":3670840,"sha256":"SUM","keep_s":600,"next":"POST /cgi-bin/upgrade?confirm=1&sha256=SUM"}
curl $A -X POST "$R/cgi-bin/upgrade?confirm=1&sha256=SUM"           # flash, keep settings
curl $A -X POST "$R/cgi-bin/upgrade?confirm=1&sha256=SUM&keep=0"    # flash, sysupgrade -n (factory settings)
```

Step 1: raw image body (not multipart), at most 4,194,304 bytes. Before reading the body the script deletes any old /tmp/fw.bin and checks MemAvailable; below 6,144 kB (`min_mem_kb` in web.conf) it refuses with 507 and reads nothing into RAM. The image goes to /tmp/fw.bin and must pass `sysupgrade -T`; otherwise it is deleted and the reply is 400 with the check output. Check the returned sha256 against sha256sums. A tested image is deleted again after `image_keep_s` (600 s) if it is not flashed, because it holds 4 MB of RAM.

Step 2: `confirm=1` needs the image's sha256 (lower-case hex, in the query string or a form body). A missing sha256 gets 400, a different one 409, so a confirm only flashes the image you checked. It then re-tests /tmp/fw.bin, replies, and runs `sysupgrade /tmp/fw.bin` (settings kept) 2 s later. Default is keep settings, because /etc/benchweb, the LAN address, Wi-Fi and SSH keys then survive and the router comes back where it was. With `keep=0` the image's own first-boot defaults apply: 99-bench sets the LAN address and key-only SSH again, and 90-benchweb makes a new web password. A config made by an image without busybox `strings` has no switch section; `/etc/uci-defaults/95-bench-switch` moves such a config to the stock switch layout at boot (see ../docs/dead-lan.md, "F2").

A failed or interrupted flash needs serial or TFTP recovery. Keep that path ready.

### POST /cgi-bin/reboot

```
curl $A -X POST $R/cgi-bin/reboot
```

### GET /

The page: status in a frame, one form per action (log, leases, clients and ping included; factory reset asks for confirmation first), file inputs for restore and firmware (a few lines of JavaScript send the file as the raw body and copy the returned sha256 into the flash form). Results show in the frame at the bottom.

## Limits

- One request at a time per change (lock). httpd forks a process per request; each request costs about 1 MB RSS while it runs, almost all shared busybox pages.
- No HTTPS. Cross-site requests are blocked by the Origin and Host checks, not by tokens; a browser that sends no Origin on a cross-site POST (none current) would not be covered.
- A connection flood (no password needed) from the LAN or WAN side still makes the web UI and SSH unresponsive while it lasts, but only httpd processes are killed.
- No limit on login attempts. Each costs an MD5-crypt; the 96-bit password makes guessing useless.
- Port control is untested on hardware (see above).
- Memory: in QEMU (malta kernel, about 6.5 MB less RAM than the router) a stored 3.85 MB image takes MemAvailable from about 6.1 MB to about 3.1 MB. The router should have about 6.5 MB more. The image is deleted after `image_keep_s` if not flashed.
