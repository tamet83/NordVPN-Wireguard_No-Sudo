# [Wireguard](https://www.wireguard.com) configuration file generator for a [NordVPN](https://nordvpn.com)

A Bash script that generates NordVPN WireGuard configuration files using NordLynx and can optionally update an existing WireGuard VPN Client profile on a UniFi Dream Machine.

This repository is based on the original project by [sfiorini/NordVPN-Wireguard](https://github.com/sfiorini/NordVPN-Wireguard).

The fork was initially created to remove the use of `sudo` when running the script as `root` inside environments such as Proxmox LXC containers. Version 2 extends the original project with automatic server selection, Standard/P2P filtering, country/city selection, latency benchmarking, configurable WireGuard addresses, and optional UniFi UDM integration.

---

## Features

Version 2 can:

- generate NordVPN WireGuard configuration files using NordLynx;
- choose between **Standard** and **P2P** NordVPN servers;
- retrieve countries and cities dynamically from the NordVPN API;
- filter only online servers;
- sort candidates by current NordVPN load;
- benchmark the least-loaded candidates using latency tests;
- automatically select the best candidate;
- disconnect an existing NordVPN tunnel before benchmarking;
- preserve or customize the WireGuard client address;
- always write client addresses using a `/32` prefix;
- optionally connect to a UniFi Dream Machine via SSH;
- discover existing UniFi WireGuard VPN Client profiles dynamically;
- update an existing UniFi VPN Client without deleting and recreating it;
- preserve the existing UniFi object and associated Traffic Routes;
- create a backup before modifying the UniFi profile;
- disable the profile and wait until its runtime `wgcltX` interface is actually removed;
- re-enable the profile;
- verify the new runtime endpoint and WireGuard handshake.

---

## Tested environment

The current version has been tested with:

- Debian 12 Bookworm
- Proxmox LXC
- NordVPN Linux client
- NordLynx
- WireGuard
- UniFi Dream Machine SE
- UniFi OS 6.x
- UniFi Network 10.x

Other Debian/Ubuntu-based systems may also work.

> [!WARNING]
> The optional UniFi integration uses local/internal UniFi Network API endpoints. These endpoints may change between UniFi Network releases. Retest the integration after major UniFi updates and always keep backups.

---

# Installation

## 1. Clone the repository

```bash
git clone https://github.com/tamet83/NordVPN-Wireguard_No-Sudo.git
cd NordVPN-Wireguard_No-Sudo
```

Make the v2 script executable:

```bash
chmod +x NordVpnToWireguard_v2.sh
```

---

## 2. Install required packages

On Debian/Ubuntu:

```bash
apt update
apt install wireguard curl jq iputils-ping net-tools openssh-client
```

The script requires:

- `nordvpn`
- `curl`
- `jq`
- `ping`
- `wg`
- `ip` or `ifconfig`

For UniFi UDM integration, it additionally requires:

- `ssh`
- `scp`

---

## 3. Install the NordVPN Linux client

Install the official NordVPN client:

```bash
sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)
```

Check that the NordVPN daemon is running:

```bash
systemctl status nordvpnd
```

If necessary:

```bash
systemctl start nordvpnd
```

---

## 4. Log in to NordVPN

Run:

```bash
nordvpn login
```

Complete the authentication process using the URL returned by the NordVPN client.

Verify the account:

```bash
nordvpn account
```

The script requires the NordVPN CLI to be authenticated, but the client does **not** need to be connected before running the script.

---

## 5. Enable NordLynx

Set NordVPN to use NordLynx:

```bash
nordvpn set technology nordlynx
```

NordLynx is NordVPN's WireGuard-based technology and uses UDP.

---

# Running the script

Start interactive mode:

```bash
./NordVpnToWireguard_v2.sh
```

The first menu is:

```text
Operation:
  1) Generate WireGuard configuration only
  2) Generate configuration and update an existing UDM WireGuard profile
Choice:
```

Both modes still allow you to choose:

- Standard or P2P;
- country;
- optional city;
- the best server based on load and latency.

---

# Mode 1 — Generate WireGuard configuration only

Select:

```text
1) Generate WireGuard configuration only
```

The script then asks for:

1. server type;
2. country;
3. optional city;
4. WireGuard address;
5. output filename.

No UniFi device is contacted in this mode.

---

## Server type

The script asks:

```text
Server type:
  1) Standard
  2) P2P
```

### Standard

Standard mode requires the NordVPN group:

```text
Standard VPN servers
```

A Standard server may also support P2P. This is normal: many NordVPN servers belong to both groups.

Special-purpose categories such as the following are excluded:

- Onion Over VPN
- Double VPN
- Dedicated IP

### P2P

P2P mode explicitly requires the NordVPN:

```text
P2P
```

group.

---

# Country and city selection

Countries are retrieved dynamically from the NordVPN API.

Example:

```text
Select country:

  1) Albania
  2) Argentina
  ...
```

After selecting a country, the script can optionally restrict the search to a specific city:

```text
Restrict the search to a city? [y/N]:
```

If enabled, only cities currently available for the selected country are displayed.

Nothing is hardcoded to a specific country or city.

---

# Automatic best-server selection

Before measuring latency, the script checks whether NordVPN is already connected.

If an active NordVPN tunnel is detected, it is disconnected before benchmarking.

This is important because measuring candidate servers through another VPN tunnel would distort the latency results.

The selection process is:

1. retrieve online NordVPN servers matching the selected type and location;
2. sort them by current NordVPN load;
3. keep the 10 least-loaded candidates;
4. ping each candidate 5 times;
5. read the average latency reported by `ping`;
6. select the server with the lowest average latency;
7. use load as a tie-breaker.

Example:

```text
Server                           Load     Avg ping
-------------------------------------------------
xx101.nordvpn.com                 10%     3.475 ms
xx102.nordvpn.com                 10%     4.045 ms
xx103.nordvpn.com                 10%     2.935 ms

Selected server: xx103.nordvpn.com
Load: 10%
Average ping: 2.935 ms
```

Three decimal places are normal because the script uses the average value reported by `ping`.

---

# WireGuard client address

After selecting the NordVPN server, the script temporarily connects to it to obtain the NordLynx parameters.

NordVPN may assign an address such as:

```text
10.5.0.2/16
```

The generated client configuration always uses a `/32` prefix:

```text
10.5.0.2/32
```

In generate-only mode, the script proposes the NordVPN-assigned IP and allows you to change only the last octet.

Example:

```text
NordVPN assigned WireGuard address: 10.5.0.2/16

Which address should be written to the new configuration?
  1) Use NordVPN address: 10.5.0.2/32
  2) Change only the last octet
```

If option `2` is selected, the script asks:

```text
Enter new last octet (1-254):
```

---

# Output filename

The generated filename is independent from the NordVPN server name and from any UniFi profile name.

Example:

```text
Output filename [NordVPN-xx103.conf]:
```

Both of the following are accepted:

```text
MyVPN
```

and:

```text
MyVPN.conf
```

The resulting file will be:

```text
MyVPN.conf
```

> [!IMPORTANT]
> Generated `.conf` files contain a WireGuard private key. Treat them as sensitive files and do not publish them.

---

# Mode 2 — Generate configuration and update a UDM profile

Select:

```text
2) Generate configuration and update an existing UDM WireGuard profile
```

The script first asks for the UniFi Dream Machine address:

```text
Enter UDM IP address or hostname:
```

You can enter either:

- an IP address;
- a DNS hostname.

Alternatively, you can define the host before running the script:

```bash
UDM_HOST=<UDM_IP_OR_HOSTNAME> ./NordVpnToWireguard_v2.sh
```

---

# Existing UDM profile discovery

Before selecting the NordVPN server, the script connects to the UDM and dynamically retrieves all existing WireGuard VPN Client profiles.

Example:

```text
WireGuard VPN profiles found on UDM:

  1) VPN_Profile_1 [10.5.0.2/32]
  2) VPN_Profile_2 [10.5.0.3/32]
  3) Cancel
```

The selected profile is remembered before continuing with the normal NordVPN workflow.

The script then still asks for:

- Standard or P2P;
- country;
- optional city;
- automatic server benchmark.

---

# WireGuard address handling in UDM mode

In UDM update mode, the NordVPN-assigned address is **not** used as the default.

Instead, the script proposes the address already configured on the selected UniFi profile.

Example:

```text
NordVPN assigned WireGuard address: 10.5.0.2/16

Selected UDM profile: VPN_Profile_2
Current UDM profile address: 10.5.0.3/32

Which address should be written to the new configuration?
  1) Keep current UDM profile address: 10.5.0.3/32
  2) Change only the last octet
```

This is useful when multiple NordVPN WireGuard clients are configured on the same gateway.

For example:

```text
VPN_Profile_1 -> 10.5.0.2/32
VPN_Profile_2 -> 10.5.0.3/32
```

Even if the NordVPN Linux client repeatedly receives the same local NordLynx address, the script preserves the address already associated with the selected UDM profile.

---

# Initial UniFi setup

The script updates **existing** WireGuard VPN Client profiles.

It does not currently create the first UniFi VPN Client profile from scratch.

Create the required WireGuard VPN Client profile(s) once from the UniFi Network interface and configure any required Traffic Routes.

After that, the script can replace the NordVPN configuration while keeping the existing UniFi profile object.

This avoids deleting and recreating the VPN Client whenever the NordVPN server changes.

---

# UniFi SSH setup

The script uses SSH and SCP to communicate with the UDM.

The default SSH user is:

```text
root
```

The default SSH key path is:

```text
$HOME/.ssh/id_ed25519_udm_nordvpn
```

These values can be overridden with environment variables if required.

---

## Create a dedicated SSH key

On the machine running the script:

```bash
ssh-keygen \
  -t ed25519 \
  -f "$HOME/.ssh/id_ed25519_udm_nordvpn" \
  -C "NordVPN-to-UDM" \
  -N ''
```

Copy the public key to the UDM:

```bash
ssh-copy-id \
  -i "$HOME/.ssh/id_ed25519_udm_nordvpn.pub" \
  root@<UDM_IP_OR_HOSTNAME>
```

The UDM SSH password is required only during this initial setup.

Test passwordless access:

```bash
ssh \
  -i "$HOME/.ssh/id_ed25519_udm_nordvpn" \
  root@<UDM_IP_OR_HOSTNAME> \
  'hostname'
```

The hostname should be returned without an SSH password prompt.

---

# UniFi API credentials

Updating the UniFi VPN profile requires authentication to the local UniFi Network API.

The UniFi username and password are **not stored in this script** and are **not stored in the Git repository**.

Instead, they are stored locally on the UDM in:

```text
/root/.unifi_nordvpn_api
```

A dedicated local UniFi administrator account is recommended for this integration.

---

## Create the API credential file

From the machine running the script:

```bash
ssh -t \
  -i "$HOME/.ssh/id_ed25519_udm_nordvpn" \
  root@<UDM_IP_OR_HOSTNAME> \
  'umask 077; read -p "UniFi username: " U; read -s -p "UniFi password: " P; echo; printf "%s\n%s\n" "$U" "$P" > /root/.unifi_nordvpn_api'
```

The password is not displayed while being entered.

The file contains two lines:

```text
username
password
```

Verify the permissions:

```bash
ssh \
  -i "$HOME/.ssh/id_ed25519_udm_nordvpn" \
  root@<UDM_IP_OR_HOSTNAME> \
  'ls -l /root/.unifi_nordvpn_api'
```

Expected permissions:

```text
-rw------- 1 root root ...
```

Mode `600` means the file is readable and writable only by `root`.

> [!IMPORTANT]
> The UniFi API password is stored in plaintext on the UDM, but the credential file is protected with restrictive filesystem permissions and is never embedded in the script or repository.

---

# Test UniFi API authentication

The credentials can be tested without printing the password:

```bash
ssh \
  -i "$HOME/.ssh/id_ed25519_udm_nordvpn" \
  root@<UDM_IP_OR_HOSTNAME> \
  'U=$(sed -n "1p" /root/.unifi_nordvpn_api); P=$(sed -n "2p" /root/.unifi_nordvpn_api); curl -sk -o /dev/null -w "%{http_code}\n" -H "Content-Type: application/json" -d "{\"username\":\"$U\",\"password\":\"$P\"}" https://127.0.0.1/api/auth/login'
```

Expected result:

```text
200
```

---

# How the UniFi update works

When a UDM profile is selected, the script:

1. connects to the UDM using the dedicated SSH key;
2. authenticates to the local UniFi API;
3. retrieves existing WireGuard VPN Client objects;
4. reads the selected profile;
5. creates a timestamped backup;
6. uploads the new WireGuard `.conf`;
7. updates the existing UniFi Network object;
8. preserves the existing profile identity;
9. temporarily disables the profile;
10. waits until the corresponding runtime `wgcltX` interface has actually disappeared;
11. re-enables the profile;
12. waits for the WireGuard interface to return;
13. verifies the runtime endpoint;
14. verifies that a WireGuard handshake is active.

The profile is updated in place rather than deleted and recreated.

This is designed to preserve references such as existing UniFi Traffic Routes.

---

# Profile backups

Before changing a UniFi VPN Client, the script stores a timestamped JSON backup on the UDM.

Example:

```text
/root/nordvpn-wireguard-VPN_Profile_1-YYYYMMDD-HHMMSS.json
```

These backup files can contain sensitive WireGuard configuration data, including private keys.

Do not publish or commit them.

---

# Runtime WireGuard reprovisioning

Updating the UniFi configuration object is not always enough to immediately replace the active runtime WireGuard endpoint.

For this reason, the script explicitly performs a disable/enable cycle.

After disabling the profile, it does **not** rely only on a fixed delay.

Instead, it repeatedly checks the corresponding runtime interface:

```bash
wg show wgcltX
```

and waits until the interface no longer exists.

Only then is the profile re-enabled.

This prevents a rapid disable/enable sequence from accidentally retaining the previous runtime WireGuard endpoint.

---

# Verify the active tunnel

On the UDM:

```bash
wg show
```

A working WireGuard client should show values similar to:

```text
interface: wgcltX

peer: ...
endpoint: <VPN_SERVER_IP>:51820
allowed ips: 0.0.0.0/0
latest handshake: 5 seconds ago
latest receive: 2 seconds ago
transfer: ...
```

Useful indicators are:

- a recent `latest handshake`;
- recent receive activity;
- increasing transfer counters.

The script performs these checks automatically after updating a profile.

---

# Endpoint IP and public exit IP

The WireGuard endpoint IP is the address used to establish the VPN tunnel.

It does not necessarily have to be the same IP address visible to Internet services.

For example:

```text
WireGuard endpoint:
203.0.113.10
```

while:

```bash
curl -4 -s https://ifconfig.me
```

could return another IP from the VPN provider's egress pool.

This can be normal.

---

# Verify UniFi Traffic Routes

If a UniFi Traffic Route sends a specific client or network through the VPN profile, verify the public IP from that client.

Example:

```bash
curl -4 -s https://ifconfig.me; echo
```

If the Traffic Route is active, the returned address should be a VPN exit IP rather than the normal WAN public IP.

If the WAN IP is returned instead, verify that:

- the Traffic Route is enabled;
- the intended device is still selected;
- the device identity/MAC address has not changed;
- the VPN profile itself is enabled and connected.

---

# Direct mode

Version 2 preserves direct command-line operation.

Examples:

Specific server:

```bash
./NordVpnToWireguard_v2.sh xx123
```

Country:

```bash
./NordVpnToWireguard_v2.sh Italy
```

Country and city:

```bash
./NordVpnToWireguard_v2.sh Italy Milan
```

Arguments in direct mode are passed directly to:

```bash
nordvpn connect
```

Direct mode generates the WireGuard configuration only and does not start the interactive UDM workflow.

---

# Run from any directory

You do not need to change into the repository directory first.

Use the complete path to the script:

```bash
/path/to/NordVPN-Wireguard_No-Sudo/NordVpnToWireguard_v2.sh
```

This is also convenient for terminal snippets or command launchers.

---

# Command-line help

Display the built-in help:

```bash
./NordVpnToWireguard_v2.sh --help
```

Display the version:

```bash
./NordVpnToWireguard_v2.sh --version
```

---

# Security notes

## Generated WireGuard configurations

Generated `.conf` files contain a WireGuard private key.

Do not publish them.

Do not paste their full contents into public issues, forums, or documentation.

---

## SSH private key

The private SSH key:

```text
$HOME/.ssh/id_ed25519_udm_nordvpn
```

must remain on the machine running the script.

Only the corresponding `.pub` key should be copied to the UDM.

---

## UniFi API credentials

The UniFi API credentials remain only on the UDM in:

```text
/root/.unifi_nordvpn_api
```

The script reads them remotely after connecting through SSH.

They are never hardcoded into the script.

---

## UniFi profile backups

Backups created on the UDM may contain private WireGuard material.

Protect them in the same way as generated `.conf` files.

---

# Troubleshooting

## `Unable to connect to NordVPN`

Check the daemon:

```bash
systemctl status nordvpnd
```

Start it if necessary:

```bash
systemctl start nordvpnd
```

Verify authentication:

```bash
nordvpn account
```

---

## Latency results appear unusually high

Make sure the benchmark is not running through an existing VPN tunnel.

Version 2 automatically disconnects an active NordVPN connection before benchmarking.

The NordVPN client can remain logged in.

---

## `No matching online servers were found`

Verify the selected country/city and server type.

Standard mode accepts regular Standard VPN servers even when they also support P2P.

Special-purpose categories are excluded.

---

## SSH connection to the UDM fails

Test manually:

```bash
ssh \
  -i "$HOME/.ssh/id_ed25519_udm_nordvpn" \
  root@<UDM_IP_OR_HOSTNAME> \
  'hostname'
```

If a password is requested, verify that the public key has been installed correctly on the UDM.

---

## UniFi API returns HTTP 401

Verify the credential file:

```text
/root/.unifi_nordvpn_api
```

Confirm that the stored UniFi account has sufficient administrative permissions.

Then repeat the API authentication test described above.

---

## UniFi profile changes but the old runtime endpoint remains

The runtime WireGuard interface must be fully removed before the profile is re-enabled.

Version 2 waits for:

```bash
wg show wgcltX
```

to report that the interface no longer exists before performing the enable operation.

---

## VPN tunnel is active but a client still uses the normal WAN

Check the UniFi Traffic Route associated with the client.

Also verify the client's public IP:

```bash
curl -4 -s https://ifconfig.me; echo
```

The problem may be the Traffic Route rather than the WireGuard tunnel itself.

---

## Git pull is blocked by local changes

Example:

```text
error: Your local changes to the following files would be overwritten by merge
```

If the local changes are not needed:

```bash
git restore NordVpnToWireguard_v2.sh
git pull
```

---

# Why `/32`?

NordLynx on Linux may expose an address with a broader prefix such as:

```text
10.5.0.2/16
```

For the UniFi WireGuard VPN Client profiles used by this project, the generated client address is written as a host route:

```text
10.5.0.2/32
```

When multiple NordVPN WireGuard clients exist on the same gateway, each can therefore use a distinct client address, for example:

```text
VPN_Profile_1 -> 10.5.0.2/32
VPN_Profile_2 -> 10.5.0.3/32
```

In UDM update mode, the current address of the selected profile is proposed automatically.

---

# Disclaimer

This project is not affiliated with NordVPN or Ubiquiti.

The UniFi integration relies on local/internal API behavior that may change in future UniFi Network releases.

Use it at your own risk and keep backups before making changes to production networking equipment.

---

# Credits

Original project:

- https://github.com/sfiorini/NordVPN-Wireguard

NordVPN:

- https://nordvpn.com/

WireGuard:

- https://www.wireguard.com/

