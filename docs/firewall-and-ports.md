# Firewall and GPUStack ports

## Current policy: firewalld off

`MAINT_DISABLE_FIREWALL=1` disables and masks `firewalld` on every maintenance
run. Masking is what makes it stick, since a `dnf upgrade` that reinstalls the
package can re-enable the unit.

```bash
systemctl disable --now firewalld
systemctl mask firewalld
systemctl is-enabled firewalld   # masked
```

To reverse it:

```bash
systemctl unmask firewalld
systemctl enable --now firewalld
```
and set `MAINT_DISABLE_FIREWALL=0` in `/etc/sysconfig/node-maintenance`, or the
next run will turn it off again.

This only holds up if the compute nodes sit on a segment behind a perimeter
firewall or a router ACL, with no route from outside. Worth confirming that
`sshd` is the only externally reachable listener:

```bash
ss -tlnp | grep -v '127.0.0.1\|::1'
```

## GPUStack ports, for reference

Needed only if firewalld is turned back on. With it off these are already open.

| Port | Use |
|---|---|
| 10150/tcp | GPUStack worker |
| 10151/tcp | GPUStack worker |
| 40000-40063/tcp | inference instance range |
| 41000-41999/tcp | inference instance range |

```bash
for p in 10150/tcp 10151/tcp 40000-40063/tcp 41000-41999/tcp; do
  firewall-cmd --permanent --add-port=$p
done
firewall-cmd --reload && firewall-cmd --list-ports
```

SELinux is a separate control and is left enforcing. If a GPUStack port fails
to bind with the firewall already off, check `ausearch -m avc -ts recent`
before blaming the network.
