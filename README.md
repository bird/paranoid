# paranoid

Isolated QEMU microVM sandboxes with WireGuard-only networking for running AI agents.

Every VM runs in a network namespace with a structural kill switch: the namespace has no internet-facing interface — only a veth to the host, whose traffic is policy-routed through WireGuard. If WG drops, traffic has nowhere to go. No firewall rule to misconfigure.

## Architecture

```
Root namespace (host)
  eth0          real internet (your NIC)
  wg-<name>     WireGuard tunnel to Mullvad
  ve<N>host     veth to agent namespace
  iptables      ve<N>host <-> wg-<name> only, everything else DROP
  policy rt     iif ve<N>host -> table N -> default dev wg-<name>

Agent namespace
  ve<N>ns       only exit path (-> host -> WG -> Mullvad)
  tap-<name>    QEMU VM NIC
  nftables      output: veth + loopback only, all IPv6 dropped
  (no direct internet interface)
  control plane API on tap gateway (:9111)

QEMU microVM (-M microvm, KVM, seccomp sandbox)
  Alpine Linux, ~2s boot, LUKS-encrypted overlay
  SSH (key-only), doas (passwordless root), Python 3
  vpn CLI for WG management, rescue-agent for emergencies
```

## Quick start

```bash
# One-time setup — registers a WG key with Mullvad automatically
sudo paranoid setup --mullvad-account 1234567890123456

# Launch a VM
sudo paranoid start --name agent1 --location us --detach

# SSH in
sudo paranoid ssh agent1
```

Inside the VM:
```bash
vpn status              # WG connection, health, transfer stats
vpn locations           # 550+ servers across 50 countries
vpn rotate jp           # switch to Japan
vpn auto-rotate 30      # rotate every 30 minutes
doas apk add git jq     # install packages (through WG tunnel)
```

With local inference:
```bash
sudo paranoid start --name agent2 \
    --local-inference 192.168.1.100:8080 \
    --auto-rotate 60 --max-cpu 200 --max-mem 1024 -d
```
```bash
# Inside the VM:
curl http://inference.local:11434/v1/models
~/rescue-agent "check why the build is failing"
```

Host-side operations:
```bash
sudo paranoid cp ./task.py agent1:/home/agent/task.py
sudo paranoid cp agent1:/home/agent/results.json ./results.json
sudo paranoid rotate agent1 --location de
sudo paranoid stop agent1
```

## Networking

**Kill switch is structural**, not just firewall rules:
- Namespace has no WG interface, no internet interface — only a veth to the host
- Host policy-routes veth traffic through WG; iptables DROP everything else
- If WG goes down, packets reach the host but have no forward path
- IPv6 dropped at both nftables (namespace) and ip6tables (host)
- DNS through Mullvad only (10.64.0.1)

**Inference pinhole** (`--local-inference`):
- Routes one specific LAN ip:port directly (bypasses WG) via the same veth
- DNAT in namespace + host, masquerade for return path
- No lateral movement — only the exact ip:port is allowed
- VM sees it as `http://inference.local:11434`

**Mullvad integration**:
- Pass your 16-digit account number — WG key auto-registered via API
- If at the 5-device limit, oldest device auto-removed
- Server list cached from Mullvad API, refreshed every 24h
- Hitless rotation via `wg set peer` (no tunnel teardown)

## Encryption

| Layer | Algorithm | Protects |
|-------|-----------|----------|
| Vault | AES-256-CBC, PBKDF2 600K iter | Master key (passphrase-protected) |
| Disk | LUKS / AES-256-XTS | VM overlay images (per-VM random key) |
| Secrets | AES-256-CBC, PBKDF2 600K iter | WG private key, SSH keys at rest |
| Runtime | tmpfs (RAM-only) | Decrypted keys, destroyed on stop |
| Network | ChaCha20-Poly1305 | All tunnel traffic (WireGuard) |
| Transport | fd passing, /dev/shm | Secrets never in /proc/cmdline |

## VM environment

- **Root access**: `doas` (passwordless, VM is the security boundary)
- **Packages**: `doas apk add <pkg>` (through WG tunnel)
- **Immutable infra** (`chattr +i`): vpn tool, rescue-agent, /etc/hosts, resolv.conf, SSH config, authorized_keys, doas.conf, init script
- **Control plane**: HTTP API on TAP gateway, `vpn` CLI wrapper
- **Rescue agent**: `~/rescue-agent` — minimal AI agent with bash tool (inference pinhole only)
- **Docs**: `~/DOCS.md` — usage reference injected per-VM

## Commands

| Command | Description |
|---------|-------------|
| `setup [--mullvad-account]` | Install deps, build kernel + base image, register WG key |
| `start [opts]` | Launch a new VM |
| `stop <name>` | Graceful QMP shutdown, tear down all resources |
| `rotate <name> [--location]` | Hot-swap WG endpoint (no VM restart) |
| `list` | Show running VMs |
| `ssh <name>` | Interactive SSH |
| `exec <name> -- cmd` | Run command via SSH |
| `cp <src> <dst>` | Copy files (`vm:path` syntax) |
| `status <name>` | VM info, WG status, firewall rules |
| `cleanup` | Remove orphaned interfaces, namespaces, rules |

### Start flags

```
--name <name>               VM name (auto-generated if omitted)
--location <cc>             Mullvad server country (us, de, gb, jp, ...)
--ram <MB>                  RAM (default: 512)
--cpus <N>                  CPUs (default: 2)
--detach, -d                Run in background
--local-inference <ip:port> LAN inference API pinhole
--auto-rotate <minutes>     Auto-rotate WG endpoint
--max-cpu <percent>         cgroup v2 CPU limit (100 = 1 core)
--max-mem <MB>              cgroup v2 memory limit
--sev                       AMD SEV memory encryption (EPYC only)
```

## Requirements

- Linux with KVM (`/dev/kvm`)
- Supported distros: Arch/CachyOS, Debian/Ubuntu, Fedora/RHEL (auto-detected)
- Mullvad VPN account (16-digit number)
- Auto-installed: qemu-system-x86, qemu-img, wireguard-tools, nftables, socat

## File layout

```
~/.config/paranoid/
  vault.key.enc             encrypted master key
  mullvad.conf.enc          encrypted WG credentials
  servers.json              cached Mullvad server list

~/.local/share/paranoid/
  base/
    vmlinuz                 microvm kernel (SHA256 verified)
    alpine-base.qcow2       read-only base rootfs
  vms/<name>/
    overlay.qcow2           LUKS-encrypted per-VM overlay
    vm.meta                 VM state (JSON)
    ssh_key.enc             encrypted SSH private key
    disk.key.enc            encrypted disk secret
    .secrets/               tmpfs (runtime only, destroyed on stop)
    console.log             VM serial output (detached mode)
    controlplane.log        control plane output
```

## Environment

```
PARANOID_PASSPHRASE     Vault passphrase (avoids interactive prompt)
PARANOID_KERNEL=/path   Custom microvm kernel (skips download + SHA256 check)
PARANOID_DEBUG=1        Verbose output
```

## Security model

The VM is the security boundary, not the user account inside it. The agent has full root access (`doas`) and can install packages, run services, and use all tools. What it cannot do:

- **Reach the internet outside WG** — structural (no interface exists)
- **Reach the LAN** — no route except the scoped inference pinhole
- **Break the sandbox plumbing** — vpn tool, networking config, SSH access, init script all immutable
- **Read host secrets** — encrypted at rest, decrypted on tmpfs only
- **Persist after stop** — overlay deleted, tmpfs unmounted, namespace destroyed
- **Escape QEMU** — seccomp sandbox, minimal virtio device surface

Reviewed through 8 adversarial security audit rounds (41 issues found and fixed).

## License

MIT
