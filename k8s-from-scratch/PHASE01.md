# Kubernetes from Scratch Lab — Phase 0: Linux Workbench

This lab is for learning Kubernetes by first understanding the Linux/container primitives underneath it.

The goal is not to use Docker to hide the details. The goal is to use a real Linux shell and manually prove that the primitives exist:

* processes
* namespaces
* network namespaces
* virtual Ethernet pairs
* cgroups
* Linux filesystem paths

Later phases will use these same ideas to explain containers, Docker Compose networking, Kubernetes Pods, Services, CoreDNS, NetworkPolicies, ConfigMaps, Secrets, Volumes, ServiceAccounts, and Ingress.

---

## Phase 0 goal

By the end of Phase 0, I should understand this picture:

```text
Mac M2
  └── Rancher Desktop Linux VM
        ├── Kubernetes
        ├── containerd
        ├── Linux kernel
        └── my lab shell
              ├── namespaces
              ├── network namespaces
              ├── veth pairs
              ├── cgroups
              └── later: hand-built containers
```

The important sentence:

```text
Kubernetes does not invent containers.
Kubernetes asks Linux nodes, via kubelet and the container runtime, to run isolated Linux processes.
```

---

## Why Rancher Desktop?

I am on an Apple Mac M2.

macOS itself does not provide Linux containers directly because Linux containers depend on Linux kernel features.

Rancher Desktop runs a Linux virtual machine on macOS. That Linux VM gives me a real Linux kernel, container runtime, and Kubernetes environment.

For this lab I enter the Linux VM directly using:

```bash
rdctl shell
```

This is better than starting another Docker container just to learn containers, because it removes one layer of confusion.

The model is:

```text
Good model for this lab:

Mac M2
  └── Rancher Desktop Linux VM
        └── rdctl shell
              └── hand-built container experiments
```

Avoid this for now:

```text
More confusing model:

Mac M2
  └── Rancher Desktop Linux VM
        └── Docker-created Ubuntu lab container
              └── hand-built container experiments
```

---

## Why use `sudo -i`?

Many of the commands in this lab create or modify Linux kernel objects:

* namespaces
* network namespaces
* virtual Ethernet pairs
* bridges
* mounts
* cgroups

Those usually need root privileges.

Instead of prefixing every command with `sudo`, I switch to a root shell once:

```bash
sudo -i
```

Then I run the lab commands as root.

This keeps the commands easier to read.

Important: because root can change important parts of the Linux VM, this lab should be done inside the Rancher Desktop VM, not on a production Linux machine.

---

## Step 0.1 — Enter the Rancher Desktop Linux VM

Run this from the Mac terminal:

```bash
rdctl shell
```

Expected prompt shape:

```text
lima-rancher-desktop:...$
```

### Why?

This gets me inside the Linux VM that Rancher Desktop uses.

This matters because containers, cgroups, namespaces, veth pairs, bridges, and Kubernetes node internals are Linux concepts.

### Kubernetes tie-back

A Kubernetes Node is a Linux machine or VM running components such as:

```text
kubelet
container runtime
CNI networking
kube-proxy or equivalent dataplane
Pods
```

In this lab, the Rancher Desktop VM is my local Kubernetes node/workbench.

---

## Step 0.2 — Confirm where I am

Run:

```bash
whoami
id
uname -a
uname -m
cat /etc/os-release
```

Example output from my machine:

```text
whoami
rorycawley

id
uid=501(rorycawley) gid=1000(rorycawley) groups=102(docker),1000(rorycawley)

uname -a
Linux lima-rancher-desktop 6.6.119-0-virt ... aarch64 Linux

uname -m
aarch64

cat /etc/os-release
NAME="Alpine Linux"
VERSION_ID=3.23.2
VARIANT_ID="rd"
```

### Why?

These commands answer:

| Command               | What it tells me                         |
| --------------------- | ---------------------------------------- |
| `whoami`              | Which user I am                          |
| `id`                  | My numeric user ID and group memberships |
| `uname -a`            | Kernel and machine information           |
| `uname -m`            | CPU architecture                         |
| `cat /etc/os-release` | Linux distribution                       |

### What I learned

I am not on macOS anymore. I am inside a Linux VM.

My architecture is:

```text
aarch64
```

That matters later because when I download Alpine minirootfs, I must download the `aarch64` version, not the `x86_64` version.

### Kubernetes tie-back

Container images are architecture-specific. On an M2 Mac, Linux inside Rancher Desktop is usually `aarch64`, so images/root filesystems need to support ARM64/aarch64.

---

## Step 0.3 — Become root for the lab

Run:

```bash
sudo -i
```

Now confirm:

```bash
whoami
id
pwd
```

Expected:

```text
root
uid=0(root) ...
/root
```

### Why?

Root is needed for many low-level Linux operations.

Root can create network namespaces, veth pairs, bridges, mounts, and cgroups.

### Container tie-back

Container runtimes do privileged setup work on behalf of containers. For example, they create namespaces, prepare mounts, wire networking, and apply cgroups before starting the container process.

### Kubernetes tie-back

The kubelet and container runtime on a node do low-level setup work. Your app container may run as a non-root user, but the node-level machinery needs privileges to create the isolated environment.

---

## Step 0.4 — Create a stable lab directory

As root, create a lab directory:

```bash
mkdir -p /root/container-lab
cd /root/container-lab
pwd
```

Expected:

```text
/root/container-lab
```

### Why not use `/Users/...`?

When I enter `rdctl shell`, I may start inside a path like:

```text
/Users/rorycawley/Repos/lab/k8s-from-scratch
```

That is a Mac-mounted filesystem path inside the Linux VM.

For Linux internals experiments involving `chroot`, mounts, root filesystems, and network namespaces, it is simpler and safer to use the VM's Linux filesystem:

```text
/root/container-lab
```

### Kubernetes tie-back

Kubernetes node internals happen on the node filesystem, not on my Mac project folder. Later, when we talk about Kubernetes volumes, we will distinguish between:

```text
container filesystem
host/node filesystem
mounted volume
persistent volume
```

---

## Step 0.5 — Check required tools

Run:

```bash
which unshare || echo "unshare missing"
which ip || echo "ip missing"
which mount || echo "mount missing"
which ps || echo "ps missing"
which tar || echo "tar missing"
which curl || echo "curl missing"
```

Expected example:

```text
/usr/bin/unshare
/sbin/ip
/bin/mount
/bin/ps
/bin/tar
/usr/bin/curl
```

### Why?

These are the tools I need for the early phases.

| Tool      | Why I need it                                               |
| --------- | ----------------------------------------------------------- |
| `unshare` | Create Linux namespaces manually                            |
| `ip`      | Create network namespaces, veth pairs, bridges, IPs, routes |
| `mount`   | Mount filesystems such as `/proc`                           |
| `ps`      | Inspect processes                                           |
| `tar`     | Extract root filesystem tarballs                            |
| `curl`    | Download Alpine minirootfs                                  |

### Container tie-back

These tools let me manually perform parts of what a container runtime automates.

### Kubernetes tie-back

Kubernetes delegates the low-level container setup to the container runtime. CNI plugins handle networking. CSI plugins handle storage. This lab exposes the lower-level Linux ideas underneath those abstractions.

---

## Step 0.6 — Prove UTS namespace isolation

First check the current hostname:

```bash
hostname
```

Expected example:

```text
lima-rancher-desktop
```

Now run:

```bash
unshare --uts --fork sh -c 'hostname phase0-test; echo "inside namespace: $(hostname)"'
```

Then run:

```bash
echo "outside namespace: $(hostname)"
```

Expected:

```text
inside namespace: phase0-test
outside namespace: lima-rancher-desktop
```

### What just happened?

I created a new UTS namespace for one process.

Inside that namespace, the process changed its hostname to:

```text
phase0-test
```

But outside that namespace, the VM hostname remained:

```text
lima-rancher-desktop
```

### Why this matters

This is a tiny example of container isolation.

A process can be given its own view of part of the Linux system.

### Container tie-back

A container is a process with isolated views of the machine.

The UTS namespace controls hostname/domain-name isolation.

### Kubernetes tie-back

When Kubernetes starts containers in a Pod, the container runtime creates namespace isolation. The Pod/container may see a different hostname or process/network environment from the node.

### Mental model

```text
Without namespace:
  process sees the same hostname as the host

With UTS namespace:
  process can see a private hostname
```

This is the first small magic trick.

---

## Step 0.7 — Prove network namespaces work

Create the directory used by named network namespaces:

```bash
mkdir -p /run/netns
```

Create a test network namespace:

```bash
ip netns add phase0test
```

List namespaces:

```bash
ip netns list
```

Expected:

```text
phase0test
```

Look inside the namespace:

```bash
ip netns exec phase0test ip addr
```

Expected:

```text
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
```

Clean up:

```bash
ip netns delete phase0test
ip netns list
```

Expected: no output from `ip netns list`.

### What just happened?

I created a separate network namespace.

Inside it, there was only a loopback interface called `lo`.

It had no normal network card, no IP address, no route, no internet, and no connection to the outside world.

### Why this matters

A network namespace is like an empty private network bubble.

A process inside it has its own:

```text
network interfaces
IP addresses
routing table
ports
firewall view
```

### Container tie-back

When a container gets its own network namespace, it does not automatically have networking. Something must wire it up.

That wiring is usually done using things like:

```text
veth pair
bridge
routes
NAT
DNS
```

### Kubernetes tie-back

A Pod gets a network namespace.

The CNI plugin wires that Pod network namespace into the cluster network.

That is why we will later learn:

```text
network namespace
  + veth pair
  + bridge/routing
  = container networking
```

### Mental model

```text
Network namespace = private network world
```

At creation time it is empty except for loopback.

---

## Step 0.8 — Prove virtual Ethernet pairs work

Create a virtual Ethernet pair:

```bash
ip link add phase0-a type veth peer name phase0-b
```

Show both ends:

```bash
ip link show | grep phase0
```

Expected shape:

```text
phase0-b@phase0-a: <BROADCAST,MULTICAST,M-DOWN> ...
phase0-a@phase0-b: <BROADCAST,MULTICAST,M-DOWN> ...
```

Delete one end:

```bash
ip link delete phase0-a
```

Confirm both ends are gone:

```bash
ip link show | grep phase0 || echo "veth pair deleted"
```

Expected:

```text
veth pair deleted
```

### If I see `RTNETLINK answers: File exists`

That means the veth pair already exists from a previous run.

Fix it with:

```bash
ip link delete phase0-a 2>/dev/null || true
ip link delete phase0-b 2>/dev/null || true
```

Then create it again:

```bash
ip link add phase0-a type veth peer name phase0-b
```

### What just happened?

A veth pair is a virtual Ethernet cable.

It has two ends:

```text
phase0-a <------ virtual cable ------> phase0-b
```

Packets entering one end come out the other end.

### Why this matters

A network namespace by itself is isolated and disconnected.

A veth pair can connect that namespace to something else.

Later we will put one end of a veth pair inside a network namespace and attach the other end to a Linux bridge.

### Container tie-back

This is how we manually wire a container-like network namespace to the outside.

### Kubernetes tie-back

CNI plugins automate this type of wiring for Pods.

In simplified form:

```text
Pod network namespace
  └── veth end
        └── host/network side
              └── bridge, routing, overlay, eBPF, or other dataplane
```

### Mental model

```text
network namespace = private room
veth pair         = network cable into the room
bridge            = virtual switch connecting rooms
```

---

## Step 0.9 — Check cgroup v2

First inspect the cgroup filesystem:

```bash
ls /sys/fs/cgroup | head
```

Expected shape:

```text
cgroup.controllers
cgroup.max.depth
cgroup.max.descendants
cgroup.procs
cgroup.stat
cgroup.subtree_control
cgroup.threads
cpu.stat
```

Now check mount info:

```bash
grep ' /sys/fs/cgroup ' /proc/self/mountinfo
```

Expected shape:

```text
... - cgroup2 cgroup ...
```

### Note about `stat -fc %T /sys/fs/cgroup`

On some Linux systems this prints:

```text
cgroup2fs
```

In the Rancher Desktop Alpine VM, I saw:

```text
UNKNOWN
```

That does not necessarily mean cgroups are missing.

The better check is:

```bash
grep ' /sys/fs/cgroup ' /proc/self/mountinfo
```

If it says `cgroup2`, then cgroup v2 is mounted.

### What are cgroups?

Namespaces control what a process can see.

Cgroups control what a process can consume.

Examples:

```text
memory
CPU
process count
I/O
```

### Container tie-back

A container runtime can place a container process into a cgroup and then apply resource limits.

### Kubernetes tie-back

When I write this in Kubernetes:

```yaml
resources:
  limits:
    memory: "100Mi"
    cpu: "500m"
```

Kubernetes, through the kubelet and runtime, eventually enforces those limits using cgroups.

### Mental model

```text
namespace = private view
cgroup    = resource budget
```

---

## Step 0.10 — Optional: check Kubernetes is running

From inside `rdctl shell`, try:

```bash
kubectl get nodes
```

If `kubectl` is not available inside the VM shell, run it from the Mac terminal instead:

```bash
kubectl get nodes
```

Expected shape:

```text
NAME                   STATUS   ROLES                  AGE   VERSION
lima-rancher-desktop   Ready    control-plane,master   ...
```

### Why?

This confirms that the Rancher Desktop VM is also running a local Kubernetes cluster.

### Kubernetes tie-back

The same Linux VM that lets me run these manual experiments also runs Kubernetes.

That means I can later compare:

```text
What I did manually
  vs
What Kubernetes creates automatically
```

---

## Step 0.11 — Optional: check container runtime direction

From the Mac side, Rancher Desktop can be configured to use either:

```text
containerd
or
dockerd/moby
```

For Kubernetes learning, `containerd` is the better mental model because Kubernetes talks to runtimes through CRI.

The important Kubernetes chain is:

```text
Kubernetes API Server
  ↓
Scheduler chooses a node
  ↓
kubelet on that node sees the Pod
  ↓
kubelet asks the container runtime through CRI
  ↓
container runtime prepares and starts containers
  ↓
Linux kernel runs isolated processes
```

This lab starts at the bottom of that chain.

---

# Phase 0 final checklist

Run these from inside `rdctl shell` after `sudo -i`:

```bash
# 1. Confirm Linux environment
whoami
uname -a
uname -m
cat /etc/os-release
```

```bash
# 2. Create lab directory
mkdir -p /root/container-lab
cd /root/container-lab
pwd
```

```bash
# 3. Check tools
which unshare
which ip
which mount
which ps
which tar
which curl
```

```bash
# 4. UTS namespace test
hostname
unshare --uts --fork sh -c 'hostname phase0-test; echo "inside namespace: $(hostname)"'
echo "outside namespace: $(hostname)"
```

```bash
# 5. Network namespace test
mkdir -p /run/netns
ip netns add phase0test
ip netns list
ip netns exec phase0test ip addr
ip netns delete phase0test
ip netns list
```

```bash
# 6. veth pair test
ip link delete phase0-a 2>/dev/null || true
ip link delete phase0-b 2>/dev/null || true
ip link add phase0-a type veth peer name phase0-b
ip link show | grep phase0
ip link delete phase0-a
ip link show | grep phase0 || echo "veth pair deleted"
```

```bash
# 7. cgroup v2 test
ls /sys/fs/cgroup | head
grep ' /sys/fs/cgroup ' /proc/self/mountinfo
```

---

# Phase 0 cleanup

If I accidentally leave behind the test namespace or veth pair:

```bash
ip netns delete phase0test 2>/dev/null || true
ip link delete phase0-a 2>/dev/null || true
ip link delete phase0-b 2>/dev/null || true
```

Then exit the root shell:

```bash
exit
```

Then exit the Rancher Desktop shell:

```bash
exit
```

---

# What Phase 0 means

Phase 0 did not build a container yet.

It proved that the Linux workbench can support the primitives needed to build one.

I proved that I can:

```text
enter the Rancher Desktop Linux VM
become root
create namespaces
create network namespaces
create virtual Ethernet pairs
inspect cgroups
work in a Linux-native lab directory
```

This gives me the base for the next phases.

---

# The key learning from Phase 0

A container is not a magic box.

A container is a Linux process with:

```text
filesystem setup
namespace isolation
network wiring
mounted storage
cgroup resource controls
```

Kubernetes builds on this.

Kubernetes does not replace Linux.

Kubernetes coordinates Linux machines to run these isolated processes reliably.

---

# The picture to remember

```text
Kubernetes desired state
  ↓
API Server stores it
  ↓
Scheduler chooses a node
  ↓
kubelet on the node acts
  ↓
container runtime starts containers
  ↓
Linux creates namespaces, mounts, cgroups, networking
  ↓
ordinary Linux processes run
```

Phase 0 is about proving the bottom layer exists.

---

# Ready for Phase 1 when...

I can explain these in simple language:

| Word              | My simple explanation                                |
| ----------------- | ---------------------------------------------------- |
| Linux VM          | The real Linux machine running under Rancher Desktop |
| root              | Admin user needed for low-level kernel setup         |
| process           | A running program                                    |
| namespace         | A private view of part of Linux                      |
| network namespace | A private network stack                              |
| veth pair         | A virtual network cable                              |
| cgroup            | A resource control/budget mechanism                  |
| kubelet           | Kubernetes node agent                                |
| container runtime | Software kubelet asks to start containers            |
| CNI               | Plugin system that wires Pod networking              |


