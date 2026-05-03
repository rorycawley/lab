# PHASE1.md — Minimum Linux for Containers and Kubernetes

This phase teaches the minimum Linux concepts needed before building a container from scratch.

The goal is not to become a Linux expert.

The goal is to understand the Linux pieces that containers, Docker Compose, and Kubernetes are built from.

---

## Phase 1 goal

By the end of Phase 1, I should understand these ideas:

```text
process
PID
/proc
filesystem root /
mounts
network interfaces
routes
DNS
cgroups
```

The key sentence:

```text
A container is an ordinary Linux process with a controlled filesystem view,
controlled process/network views, controlled mounts, and controlled resource usage.
```

Kubernetes tie-back:

```text
Kubernetes schedules Pods, but Linux runs processes.
Kubernetes describes desired state, but the node implements it using Linux primitives.
```

---

## Starting point

From the Mac terminal:

```bash
rdctl shell
```

Become root:

```bash
sudo -i
```

Go to the lab directory:

```bash
mkdir -p /root/container-lab
cd /root/container-lab
pwd
```

Expected:

```text
/root/container-lab
```

---

# 1. Processes

## Commands

```bash
ps
```

```bash
ps -ef | head
```

```bash
echo $$
```

```bash
ps | awk -v pid=$$ '$1 == pid {print}'
```

## What these commands do

| Command                                   | Meaning                                                |
| ----------------------------------------- | ------------------------------------------------------ |
| `ps`                                      | Show running processes visible to this shell           |
| `ps -ef \| head`                          | Show the first few processes in the wider process list |
| `echo $$`                                 | Show the PID of my current shell                       |
| `ps \| awk -v pid=$$ '$1 == pid {print}'` | Show the `ps` row for my current shell                 |

## Important note about BusyBox

Rancher Desktop’s VM is Alpine-based and uses BusyBox tools.

This command may not work:

```bash
ps -p $$ -f
```

If it fails with:

```text
ps: unrecognized option: p
```

use this instead:

```bash
ps | awk -v pid=$$ '$1 == pid {print}'
```

## What I should notice

When I run `ps`, I may see Kubernetes-related processes such as:

```text
containerd
k3s server
containerd-shim-runc-v2
/pause
coredns
traefik
metrics-server
```

That is a major clue.

The Rancher Desktop VM is a real Kubernetes node/workbench, and Kubernetes is running as ordinary Linux processes.

## Container tie-back

A container is not a tiny VM.

At the bottom it is a Linux process.

```text
container
  └── process
```

## Kubernetes tie-back

A Kubernetes Pod eventually becomes Linux processes running on a node.

```text
Kubernetes YAML
  ↓
kubelet sees desired state
  ↓
containerd/runc starts a container
  ↓
Linux runs ordinary processes
```

---

# 2. PID and `/proc`

## Commands

```bash
echo "My shell PID is $$"
```

```bash
cat /proc/$$/status | head -25
```

```bash
readlink /proc/$$/exe
```

```bash
readlink /proc/$$/cwd
```

```bash
tr '\0' ' ' < /proc/$$/cmdline; echo
```

## What these commands do

| Command                          | Meaning                                           |
| -------------------------------- | ------------------------------------------------- |
| `echo $$`                        | Print my current shell process ID                 |
| `cat /proc/$$/status`            | Show live status information for my shell process |
| `readlink /proc/$$/exe`          | Show the executable file used by my shell process |
| `readlink /proc/$$/cwd`          | Show my shell process’s current working directory |
| `tr '\0' ' ' < /proc/$$/cmdline` | Show the command line used to start the process   |

## Example observations

I may see something like:

```text
Pid:    11394
PPid:   11393
Uid:    0       0       0       0
Gid:    0       0       0       0
NSpid:  11394
```

And:

```text
/bin/busybox
```

for the executable.

On Alpine, `/bin/sh` is often provided by BusyBox.

## What `/proc` is

`/proc` is a live view into process and kernel information.

For a process with PID `11394`, Linux exposes information under:

```text
/proc/11394
```

For my current shell, I can use:

```text
/proc/$$
```

because `$$` means “my current shell PID”.

## Container tie-back

When we later use a PID namespace, a process may see itself as PID `1` inside the container even though the host sees a different PID.

```text
Outside container:
  PID 48291

Inside container:
  PID 1
```

Same process. Different namespace view.

## Kubernetes tie-back

Inside a Kubernetes container, `/proc` shows the process view from inside that container’s namespaces.

This matters because tools like `ps` read from `/proc`.

Later, when we build a container-like environment manually, we will need to mount `/proc` inside it.

---

# 3. Filesystem root `/`

## Commands

```bash
pwd
```

```bash
ls /
```

```bash
ls /root
```

```bash
ls /etc | head
```

```bash
readlink /proc/$$/root
```

```bash
readlink /proc/$$/cwd
```

## What these commands do

| Command                  | Meaning                                          |
| ------------------------ | ------------------------------------------------ |
| `pwd`                    | Show the current working directory               |
| `ls /`                   | Show the top of the filesystem tree              |
| `ls /root`               | Show root user’s home area                       |
| `ls /etc \| head`        | Show some system configuration files             |
| `readlink /proc/$$/root` | Show what `/` means for my current shell process |
| `readlink /proc/$$/cwd`  | Show where my shell is currently working         |

## What I should notice

For the current shell, I should see:

```text
readlink /proc/$$/root
/
```

That means:

```text
For this shell process, / means the Rancher Desktop VM root filesystem.
```

## Container tie-back

A process has a filesystem root.

Later, with `chroot`, we will change what `/` means for a process.

```text
Before chroot:
  / means the Rancher Desktop VM filesystem

After chroot:
  / means /root/container-lab/rootfs
```

This is one of the first filesystem tricks behind containers.

## Kubernetes tie-back

When Kubernetes starts a container from an image, the container process sees a root filesystem prepared from that image.

This YAML:

```yaml
containers:
  - name: web
    image: alpine
```

means the container process eventually gets a filesystem view based on the Alpine image.

---

# 4. Mounts

## Commands

```bash
mount | head
```

```bash
cat /proc/mounts | head
```

```bash
mount | grep ' /proc '
```

```bash
mount | grep ' /sys '
```

```bash
mount | grep ' /Users ' || true
```

## What these commands do

| Command                              | Meaning                                                  |
| ------------------------------------ | -------------------------------------------------------- |
| `mount \| head`                      | Show the first few mounted filesystems                   |
| `cat /proc/mounts \| head`           | Show mounts from the kernel’s point of view              |
| `mount \| grep ' /proc '`            | Find the `/proc` mount                                   |
| `mount \| grep ' /sys '`             | Find the `/sys` mount                                    |
| `mount \| grep ' /Users ' \|\| true` | Look for Mac filesystem mount, but do not fail if absent |

## Example observations

I may see:

```text
proc on /proc type proc
sysfs on /sys type sysfs
tmpfs on / type tmpfs
tmpfs on /run type tmpfs
```

## What a mount is

A mount attaches a filesystem at a path.

Examples:

```text
/proc = live process/kernel information
/sys  = system/kernel/device/cgroup-related information
/run  = runtime state
```

## Container tie-back

Containers use mounts heavily:

```text
container root filesystem
/proc inside the container
/dev inside the container
bind mounts
volumes
tmpfs mounts
```

Later, after creating a chroot, we will mount `/proc` into it so `ps` works correctly.

## Kubernetes tie-back

This Kubernetes YAML:

```yaml
volumeMounts:
  - name: app-data
    mountPath: /data
```

means:

```text
Mount some storage into the container filesystem at /data.
```

So Kubernetes volumes are Linux mounts arranged by Kubernetes and the container runtime.

---

# 5. Network interfaces

## Commands

```bash
ip -brief addr
```

```bash
ip addr
```

```bash
ip link show | head -40
```

## What these commands do

| Command                    | Meaning                                            |
| -------------------------- | -------------------------------------------------- |
| `ip -brief addr`           | Show interfaces and IP addresses in a compact form |
| `ip addr`                  | Show detailed interface/IP information             |
| `ip link show \| head -40` | Show network links/interfaces                      |

## Example observations from Rancher Desktop

I may see:

```text
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0             UP             192.168.5.15/24
vznat            UP             192.168.64.3/24
flannel.1        UNKNOWN        10.42.0.0/32
cni0             UP             10.42.0.1/24
veth...          UP
```

## What these mean

| Interface   | Meaning                                          |
| ----------- | ------------------------------------------------ |
| `lo`        | Loopback, localhost                              |
| `eth0`      | VM network interface                             |
| `vznat`     | Rancher Desktop/Lima NAT-style interface         |
| `flannel.1` | Kubernetes/Flannel networking machinery          |
| `cni0`      | Kubernetes CNI bridge for Pods on this node      |
| `veth...`   | Virtual Ethernet links to Pod network namespaces |

## Important Kubernetes observation

Lines like this are very important:

```text
veth095e26af@if2 ... master cni0 ... link-netns cni-...
```

This means:

```text
Host-side veth
  is attached to cni0
  and its other end is inside a Pod network namespace
```

Picture:

```text
Pod network namespace
  └── eth0
       │
       │ veth pair
       │
Host-side veth
  └── attached to cni0 bridge
```

## Container tie-back

A container with its own network namespace needs a network interface inside that namespace.

Later, we will manually create:

```text
web namespace
  └── eth0: 10.200.1.2

client namespace
  └── eth0: 10.200.1.3
```

## Kubernetes tie-back

CNI plugins create and wire Pod network interfaces.

In this Rancher Desktop/K3s environment, we saw real Kubernetes networking objects:

```text
flannel.1
cni0
veth...
cni-* network namespaces
```

This is Kubernetes networking made visible as Linux networking.

---

# 6. Routes

## Commands

```bash
ip route
```

```bash
ip route get 1.1.1.1
```

```bash
ip route get 10.42.0.2 || true
```

## What these commands do

| Command                  | Meaning                                              |
| ------------------------ | ---------------------------------------------------- |
| `ip route`               | Show the routing table                               |
| `ip route get 1.1.1.1`   | Ask Linux how it would reach `1.1.1.1`               |
| `ip route get 10.42.0.2` | Ask Linux how it would reach a likely Pod-network IP |

## Example observations

I may see:

```text
default via 192.168.5.2 dev eth0 metric 202
default via 192.168.64.1 dev vznat metric 203
10.42.0.0/24 dev cni0 proto kernel scope link src 10.42.0.1
```

This means:

```text
General traffic goes out via a default route.
Pod network traffic for 10.42.0.0/24 goes through cni0.
```

Example:

```text
ip route get 1.1.1.1
1.1.1.1 via 192.168.5.2 dev eth0 src 192.168.5.15
```

Meaning:

```text
To reach 1.1.1.1, send traffic through eth0 via 192.168.5.2.
```

Example:

```text
ip route get 10.42.0.2
10.42.0.2 dev cni0 src 10.42.0.1
```

Meaning:

```text
To reach Pod IP 10.42.0.2, send traffic through cni0.
```

## Container tie-back

Interfaces are not enough.

A network namespace also needs routes.

Without routes, packets do not know where to go.

## Kubernetes tie-back

CNI is responsible for making Pod networking work.

That includes interface setup and routing/dataplane setup.

---

# 7. DNS

## Commands

```bash
cat /etc/resolv.conf
```

```bash
cat /etc/hosts
```

```bash
nslookup localhost 2>/dev/null || true
```

```bash
ping -c 1 localhost
```

```bash
ping -c 1 1.1.1.1
```

```bash
ping -c 1 google.com
```

## What these commands do

| Command                | Meaning                             |
| ---------------------- | ----------------------------------- |
| `cat /etc/resolv.conf` | Show DNS resolver configuration     |
| `cat /etc/hosts`       | Show local static name mappings     |
| `nslookup localhost`   | Try DNS lookup for localhost        |
| `ping localhost`       | Test loopback/local name resolution |
| `ping 1.1.1.1`         | Test network by IP, no DNS needed   |
| `ping google.com`      | Test DNS plus network reachability  |

## Example observations

I may see:

```text
nameserver 192.168.5.2
```

This means:

```text
The VM asks 192.168.5.2 for DNS.
```

I may see in `/etc/hosts`:

```text
127.0.0.1       localhost localhost.localdomain
::1             localhost localhost.localdomain
192.168.5.2     host.lima.internal
```

## DNS vs routing

DNS answers:

```text
What IP address is this name?
```

Routing answers:

```text
Where should I send packets for this IP address?
```

Example:

```text
google.com
  ↓ DNS
209.85.202.113
  ↓ route lookup
send packet through eth0
```

## Container tie-back

Docker Compose allows one service to call another by name:

```text
http://web:8080
```

That works because Compose provides DNS/service-name resolution.

In our manual lab, we will first fake service discovery using `/etc/hosts`:

```text
10.200.1.2 web
10.200.1.3 client
```

## Kubernetes tie-back

Kubernetes uses CoreDNS.

That is what allows Pods to resolve names like:

```text
web
web.default
web.default.svc
web.default.svc.cluster.local
```

Kubernetes Service plus CoreDNS gives stable service names for changing Pods.

---

# 8. Cgroups

## Commands

```bash
cat /proc/self/cgroup
```

```bash
ls /sys/fs/cgroup | head
```

```bash
grep ' /sys/fs/cgroup ' /proc/self/mountinfo
```

If `/proc/self/cgroup` shows something like:

```text
0::/openrc.sshd
```

then check the matching cgroup path:

```bash
cat /sys/fs/cgroup/openrc.sshd/memory.current 2>/dev/null || echo "not visible"
```

```bash
cat /sys/fs/cgroup/openrc.sshd/memory.max 2>/dev/null || echo "not visible"
```

## What these commands do

| Command                                        | Meaning                                         |
| ---------------------------------------------- | ----------------------------------------------- |
| `cat /proc/self/cgroup`                        | Show which cgroup my current process belongs to |
| `ls /sys/fs/cgroup \| head`                    | Show cgroup v2 control files                    |
| `grep ' /sys/fs/cgroup ' /proc/self/mountinfo` | Confirm cgroup v2 is mounted                    |
| `memory.current`                               | Current memory usage for that cgroup            |
| `memory.max`                                   | Memory limit for that cgroup                    |

## Example observations

I saw:

```text
0::/openrc.sshd
```

That means my shell process belongs to:

```text
/sys/fs/cgroup/openrc.sshd
```

I saw:

```text
211595264
```

from:

```bash
cat /sys/fs/cgroup/openrc.sshd/memory.current
```

That means:

```text
This cgroup is currently using about 211 MB of memory.
```

I saw:

```text
max
```

from:

```bash
cat /sys/fs/cgroup/openrc.sshd/memory.max
```

That means:

```text
There is no explicit memory limit on this cgroup.
```

## Important note about `stat`

This command may show `UNKNOWN` in Rancher Desktop Alpine:

```bash
stat -fc %T /sys/fs/cgroup
```

That is okay.

The better confirmation is:

```bash
grep ' /sys/fs/cgroup ' /proc/self/mountinfo
```

Look for:

```text
- cgroup2 cgroup2
```

## Container tie-back

Namespaces control what a process can see.

Cgroups control what a process can consume.

```text
namespace = private view
cgroup    = resource budget
```

## Kubernetes tie-back

This Kubernetes YAML:

```yaml
resources:
  limits:
    memory: "128Mi"
    cpu: "500m"
```

is enforced on the node using Linux cgroups.

A memory limit of `128Mi` eventually becomes a cgroup memory control such as:

```text
memory.max = 134217728
```

---

# Phase 1 final mental model

A container is built from ordinary Linux pieces:

```text
process
  + PID
  + /proc view
  + filesystem root
  + mounts
  + network interfaces
  + routes
  + DNS config
  + cgroups
```

Kubernetes coordinates those pieces at scale:

```text
Pod
  = one or more container processes
  + shared Pod network namespace
  + mounted volumes
  + ServiceAccount identity
  + resource limits
  + labels
  + lifecycle rules
```

The node-level chain is:

```text
Kubernetes desired state
  ↓
kubelet
  ↓
containerd/runc
  ↓
Linux kernel primitives
  ↓
ordinary Linux processes
```

---

# Phase 1 final checkpoint

Before moving to Phase 2, I should be able to explain these in my own words:

| Concept           | Simple explanation                                 |
| ----------------- | -------------------------------------------------- |
| Process           | A running program                                  |
| PID               | The number Linux uses to identify a process        |
| `/proc`           | Live process/kernel information exposed as files   |
| `/`               | The top of a process’s filesystem view             |
| Mount             | A filesystem attached at a path                    |
| Network interface | A real or virtual network card                     |
| Route             | A rule for where packets go                        |
| DNS               | Name-to-IP lookup                                  |
| Cgroup            | A resource control/budget mechanism                |
| CNI               | Kubernetes plugin system that wires Pod networking |
| CoreDNS           | Kubernetes DNS service for resolving Service names |

---

# Cleanup

Phase 1 does not create persistent lab resources, but it is always safe to run:

```bash
ip netns delete phase0test 2>/dev/null || true
ip link delete phase0-a 2>/dev/null || true
ip link delete phase0-b 2>/dev/null || true
```

Exit root:

```bash
exit
```

Exit the Rancher Desktop shell:

```bash
exit
```

---

# Ready for Phase 2 when...

I understand this sentence:

```text
An image is, in large part, a packaged filesystem that becomes the root filesystem view for a container process.
```

Phase 2 will create this filesystem manually:

```text
/root/container-lab/rootfs
  ├── bin
  ├── etc
  ├── lib
  ├── usr
  └── ...
```

That will prepare us for Phase 3: `chroot`.

