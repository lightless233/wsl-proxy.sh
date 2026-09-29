# WSL proxy rules

`wsl-proxy.sh` redirects this WSL instance's outbound TCP traffic to local
redsocks and DNS requests on port 53 to Clash on the Windows host. Private and
reserved IPv4 networks, the Windows host, and `BYPASS_IPS` go directly. It does
not proxy UDP other than DNS or IPv6.

## Manual control

```sh
./wsl-proxy.sh start
./wsl-proxy.sh status
./wsl-proxy.sh stop
./wsl-proxy.sh restart
```

The commands use `sudo` for iptables when run as a regular user. `status` prints
`active` (exit 0), `stopped` (exit 3), or `partial or configuration changed`
(exit 1), followed by the current IPv4 NAT table rules (`iptables -t nat -S`).
`start` refreshes the rules, so it is safe to run repeatedly.

## Start at WSL boot

WSL must have systemd enabled in `/etc/wsl.conf` (`[boot] systemd=true`). The
unit depends on `redsocks.service`. Install and enable it with:

```sh
./install.sh
sudo systemctl status wsl-proxy.service
```

Once installed, use `sudo systemctl start|stop|restart wsl-proxy.service` to
control it, and use `/usr/local/sbin/wsl-proxy status` to inspect the actual
iptables rules. Disable boot startup and remove the rules with
`sudo systemctl disable --now wsl-proxy.service`. The unit calls
`/usr/local/sbin/wsl-proxy`, which is a copy of the script at install time;
run `./install.sh` again after editing the script.

Defaults can be overridden in `/etc/default/wsl-proxy`:

```sh
HOST_IP=172.19.96.1
CLASH_DNS_PORT=1053
REDSOCKS_PORT=12345
BYPASS_IPS="38.207.133.215 203.0.113.10"
DNS_TCP=0
```

Use `sudo systemctl restart wsl-proxy.service` after changing that file. The
default `HOST_IP` matches the current `/etc/redsocks.conf` upstream; if the WSL
gateway changes, update both addresses. Set `DNS_TCP=1` only if Clash listens
for TCP DNS on the configured port.
