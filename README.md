# [Wireguard](https://www.wireguard.com) configuration file generator for a [NordVPN](https://nordvpn.com)

I cloned the original repository because the provided script used the sudo command, which is not compatible with my Proxmox installation, and therefore it caused errors in the two lines of the script where the VPN encryption keys were supposed to be generated. The following steps are the same provided form the original repo but is intended specifically for headless PC running for example Proxmox.

A `bash` scripts that generates [Wireguard](https://www.wireguard.com) configuration file for a [NordVPN](https://nordvpn.com) connection.

## INSTALL

This guide assumes the use of [Ubuntu](https://ubuntu.com). A similar install procedure will work on other distros.

### Clone this project

First let's clone this project so that you'll have the script on your target [Ubuntu](https://ubuntu.com) system.

```
git clone https://github.com/tamet83/NordVPN-Wireguard_No-Sudo.git

```

### Install required packages

```bash
apt install wireguard curl jq net-tools
```

### Install [NordVPN](https://nordvpn.com) client

Execute the following command and follow the on screen instructions:

```bash
sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)
```

## Login to your [NordVPN](https://nordvpn.com) account

The procedure differs if you have `MFA` enabled on your account:

1. `MFA` is ENABLED on your account

   ```bash
   nordvpn login
   ```

   This will return a URL link.  
   Open the link on any browser, on any machine and perform the login.  
   Cancel out of the `Open with` popup, and copy the link that is assigned to the `Continue` link, under the message saying `You've successfully logged in`.

   Back to the terminal

   ```bash
   nordvpn login --callback "The link you copied"
   ```

   And it will log you in.

2. `MFA` is NOT ENABLED on your account (This mode has been discontinued)

   Use `legacy` username and password to login.

   > Note: This will NOT work if you have `Multi Factor Authentication` enabled. (See above for the `MFA` method)

   ```bash
   nordvpn login --legacy​
   ```

## Change protocol to NordLynx

After a successful login, please set [NordVPN](https://nordvpn.com) to use `NordLynx` protocol.

```bash
nordvpn set technology nordlynx
```

## Generate [Wireguard](https://www.wireguard.com) configuration files

The script is quite simple and can be run without parameters to generate a config file for the recommended server:

```bash
$ ./NordVpnToWireguard.sh
```
Result
```
Connect to NordVPN to gather connection parameters....
Wireguard configuration file NordVPN-us1234.conf created successfully!
```

Requesting a specific country:

```bash
$ ./NordVpnToWireguard.sh Canada
```
Result
```
Connect to NordVPN to gather connection parameters....
Wireguard configuration file NordVPN-ca1234.conf created successfully!
```

Requesting a specific city

```bash
$ ./NordVpnToWireguard.sh Berlin
```
Result
```
Connect to NordVPN to gather connection parameters....
Wireguard configuration file NordVPN-de1234.conf created successfully!
```

Requesting a specific country and city

```bash
$ ./NordVpnToWireguard.sh Japan Tokyo
```
Result
```
Connect to NordVPN to gather connection parameters....
Wireguard configuration file NordVPN-jp1234.conf created successfully!
```

Requesting a specific server group

```bash
$ ./NordVpnToWireguard.sh Double_VPN
```
Result
```
Connect to NordVPN to gather connection parameters....
Wireguard configuration file NordVPN-ca-us1234.conf created successfully!
```

Getting help:

```bash
$ ./NordVpnToWireguard.sh --help
Usage: NordVpnToWireguard [command options] [<country>|<server>|<country_code>|<city>|<group>|<country> <city>]
Command Options includes:
   <country>       argument to create a Wireguard config for a specific country. For example: 'NordVpnToWireguard Australia'
   <server>        argument to create a Wireguard config for a specific server. For example: 'NordVpnToWireguard jp35'
   <country_code>  argument to create a Wireguard config for a specific country. For example: 'NordVpnToWireguard us'
   <city>          argument to create a Wireguard config for a specific city. For example: 'NordVpnToWireguard Hungary Budapest'
   <group>         argument to create a Wireguard config for a specific servers group. For example: 'NordVpnToWireguard connect Onion_Over_VPN'
   -h | --help     - displays this message.
```

## Use the generated [Wireguard](https://www.wireguard.com) configuration files

Import the file/s with the  [Wireguard](https://www.wireguard.com) client in any platform and activate the `VPN`.

## Why this works

The issue is not UniFi's general ability to run multiple VPN clients. The actual problem is that NordVPN OpenVPN profiles can expose the same tunnel client IP/subnet, which creates an overlap when two tunnels are imported into UniFi at the same time.

With the default OpenVPN configuration files from NordVPN, both client tunnels may end up presenting the same tunnel address on the UniFi side. As a result, UniFi does not treat them as two fully distinct client interfaces, and parallel tunnels either fail or conflict.

This workaround avoids that limitation by switching from OpenVPN to WireGuard configurations derived from an active NordLynx session. Once the WireGuard configuration is generated, the `Address` field can be adjusted so that each imported client profile uses a unique local tunnel address. That removes the overlap on the UniFi side and allows both tunnels to coexist.

In practical terms, the process is:

1. Generate a WireGuard configuration from an active NordLynx connection.
2. Create a second configuration for another NordVPN endpoint.
3. Assign a different `Address` value to each configuration.
4. Import both profiles into UniFi.
5. Use UniFi policy-based routing / traffic routes to send different traffic through each tunnel.

This does not change NordVPN server behavior. It avoids a local client-side address collision inside UniFi, which is the actual reason the dual-tunnel setup fails with the stock OpenVPN profiles.

## Known limitations

This is a workaround, not an official NordVPN or Ubiquiti method.

A few caveats apply:

- The generated configuration is based on parameters extracted from an active NordLynx session.
- Long-term behavior after UniFi OS updates, NordVPN client changes, or reconnect events should be considered unverified unless tested.
- If NordVPN changes how NordLynx session parameters are exposed, this method may stop working.
- Each tunnel should be validated after import, reboot, reconnect, or gateway upgrade.
- This solution is intended to avoid local tunnel address overlap in UniFi. It should not be interpreted as a general-purpose method for arbitrarily rewriting NordVPN tunnel parameters.

## Validation steps

After importing both WireGuard profiles into UniFi, verify the setup carefully:

1. Confirm that both VPN clients connect successfully.
2. Confirm that each client shows a different tunnel `Address`.
3. Create separate traffic routes / policy-based routing rules for the intended devices, VLANs, or networks.
4. Test public egress IP from each routed client group and verify that each one exits through the expected NordVPN endpoint.
5. Restart one tunnel and confirm that the other remains unaffected.
6. Reboot the UniFi gateway and verify that both tunnels reconnect correctly.
7. Re-test all routing policies after reboot.
8. Check for WAN leakage if one tunnel goes down and make sure failover behavior matches your design.

## Notes

Use distinct local tunnel addresses for each WireGuard profile imported into UniFi.

Example:

```ini
# Tunnel A
[Interface]
Address = 10.100.0.2/32

# Tunnel B
[Interface]
Address = 10.100.0.3/32
