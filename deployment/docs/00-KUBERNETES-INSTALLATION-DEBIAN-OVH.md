# Kubernetes Installation on Debian 12
## Complete Step-by-Step Guide for Production Matrix/Synapse Deployment

**Prerequisites:** VMs already provisioned with SSH access
**Target Environment:** Virtual Machines running Debian 12 (Bookworm)
**Kubernetes Version:** 1.28+
**Container Runtime:** containerd
**Network Plugin:** Calico
**Target Deployment:** Matrix/Synapse HA Cluster (scalable 100-20K+ CCU)

---

## Table of Contents

1. [Infrastructure Requirements](#1-infrastructure-requirements)
2. [Pre-Installation Preparation](#2-pre-installation-preparation)
3. [System Configuration (All Nodes)](#3-system-configuration-all-nodes)
4. [Container Runtime Installation](#4-container-runtime-installation)
5. [Kubernetes Components Installation](#5-kubernetes-components-installation)
6. [Control Plane Initialization](#6-control-plane-initialization)
7. [Worker Nodes Join](#7-worker-nodes-join)
8. [Network Plugin Installation](#8-network-plugin-installation)
9. [Storage Configuration](#9-storage-configuration)
10. [Validation and Testing](#10-validation-and-testing)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Infrastructure Requirements

### 1.1 Server/VM Prerequisites

**ASSUMPTION:** You have already provisioned VMs with SSH root access.

Server specifications depend on your deployment scale. See SCALING-GUIDE.md for detailed requirements.

The examples below show typical node types. Actual quantities and resources vary by scale:

#### Control Plane Nodes (Always 3 nodes for HA)
- **Quantity:** 3 nodes (all scales)
- **vCPU:** 4-8 cores each (scale-dependent)
- **RAM:** 8-16 GiB each
- **Storage:** 100-200 GiB SSD each
- **Network:** 1-10 Gbps
- **OS:** Debian 12 (Bookworm) 64-bit
- **Purpose:** Kubernetes control plane (API server, etcd, scheduler, controller-manager)

**Examples:**
- **100 CCU:** 3 nodes @ 4 vCPU, 8GB RAM
- **20K CCU:** 3 nodes @ 8 vCPU, 16GB RAM

#### Database Nodes (3-5 nodes depending on scale)
- **vCPU:** 4-32 cores each
- **RAM:** 16-128 GiB each
- **Storage:** 500GB-4TB NVMe SSD each
- **Network:** 10 Gbps recommended
- **OS:** Debian 12 (Bookworm) 64-bit
- **Purpose:** CloudNativePG PostgreSQL cluster
- **Label:** `node-role=database`

**Examples:**
- **100 CCU:** 3 nodes @ 4 vCPU, 16GB RAM, 500GB NVMe
- **20K CCU:** 5 nodes @ 32 vCPU, 128GB RAM, 4TB NVMe

#### Storage Nodes (4-12 nodes in pools of 4)
- **vCPU:** 4-16 cores each
- **RAM:** 8-32 GiB each
- **Storage:** 1-4 TiB per node
- **Network:** 10 Gbps recommended
- **OS:** Debian 12 (Bookworm) 64-bit
- **Purpose:** MinIO object storage (EC:4 per pool)
- **Label:** `node-role=storage`

**Examples:**
- **100 CCU:** 4 nodes @ 4 vCPU, 8GB RAM, 1TB (1 pool)
- **20K CCU:** 12 nodes @ 16 vCPU, 32GB RAM, 4TB (3 pools)

#### Application Nodes (3-21 nodes depending on scale)
- **vCPU:** 8-32 cores each
- **RAM:** 16-128 GiB each
- **Storage:** 200-2000 GiB SSD each
- **Network:** 1-10 Gbps
- **OS:** Debian 12 (Bookworm) 64-bit
- **Purpose:** Synapse main + workers, monitoring
- **Label:** `node-role=application`

**Examples:**
- **100 CCU:** 3 nodes @ 8 vCPU, 16GB RAM, 200GB SSD
- **20K CCU:** 21 nodes @ 32 vCPU, 128GB RAM, 2TB SSD

#### Call Server Nodes (2-10 nodes depending on scale)
- **vCPU:** 4-16 cores each
- **RAM:** 8-32 GiB each
- **Storage:** 50-200 GiB SSD each
- **Network:** 10 Gbps (critical for media)
- **OS:** Debian 12 (Bookworm) 64-bit
- **Purpose:** LiveKit SFU + coturn TURN servers
- **Labels:** `livekit=true` or `coturn=true`
- **Note:** Requires public IP or port forwarding for UDP

**Examples:**
- **100 CCU:** 2 nodes @ 4 vCPU, 8GB RAM
- **20K CCU:** 10 nodes @ 16 vCPU, 32GB RAM
- **Storage:** 50 GiB SSD each
- **Network:** 1 Gbps
- **OS:** Debian 12 (Bookworm) 64-bit
- **Purpose:** coturn TURN/STUN servers
- **Label:** `coturn=true`
- **Note:** Requires public IP for client connectivity

#### Infrastructure Nodes (2 nodes)
- **Quantity:** 2 nodes
- **vCPU:** 8 cores each
- **RAM:** 32 GiB each
- **Storage:** 500 GiB SSD each
- **Network:** 1 Gbps
- **OS:** Debian 12 (Bookworm) 64-bit
- **Purpose:** Monitoring (Prometheus, Grafana, Loki), Ingress controller
- **Label:** `node-role=infrastructure`

### 1.3 DNS Configuration

**CRITICAL:** Proper DNS is essential for Kubernetes.

#### Option 1: Use OVH DNS or External DNS
- Create A records for each node (e.g., k8s-master-01.example.com)
- Create A record for API server load balancer (if using)

#### Option 2: Configure /etc/hosts on All Nodes

```bash
# Control Plane
192.168.0.10  k8s-master-01
192.168.0.11  k8s-master-02
192.168.0.12  k8s-master-03

# Database nodes
192.168.0.20  k8s-db-01
192.168.0.21  k8s-db-02
192.168.0.22  k8s-db-03

# Storage nodes
192.168.0.30  k8s-storage-01
192.168.0.31  k8s-storage-02
192.168.0.32  k8s-storage-03
192.168.0.33  k8s-storage-04

# ... etc for all nodes
```

**NOTE:** Update /etc/hosts on EVERY node with ALL node entries.

---

## 2. Pre-Installation Preparation

### 2.1 Update System (Execute on ALL Nodes)

**WHERE:** SSH into each node
**WHEN:** Before any Kubernetes installation
**WHY:** Ensure latest security patches and package compatibility
**HOW:** Run as root or with sudo

```bash
# Update package lists
apt-get update

# Upgrade all packages
apt-get upgrade -y

# Install essential tools
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    vim \
    wget \
    git \
    htop \
    net-tools

# Reboot if kernel was updated
[ -f /var/run/reboot-required ] && reboot
```

**WHAT THIS DOES:**
- `apt-get update`: Refreshes package repository index
- `apt-get upgrade -y`: Upgrades installed packages, `-y` auto-confirms
- `apt-transport-https`: Allows apt to retrieve packages over HTTPS
- `ca-certificates`: Common CA certificates for SSL verification
- `curl`: Command-line tool for transferring data
- `gnupg`: GNU Privacy Guard for package verification
- `lsb-release`: Linux Standard Base version reporting
- Reboot check: Kernel updates require reboot for changes to take effect

### 2.2 Configure Hostnames (Execute on EACH Node)

**WHERE:** On each node individually
**WHEN:** Before Kubernetes installation
**WHY:** Kubernetes uses hostnames for node identification
**HOW:** Set unique hostname per node

```bash
# On k8s-master-01:
hostnamectl set-hostname k8s-master-01

# On k8s-master-02:
hostnamectl set-hostname k8s-master-02

# ... repeat for each node with appropriate hostname
```

**VERIFY:**
```bash
hostname
hostname -f  # Should show FQDN if DNS configured
```

### 2.3 Disable Swap (CRITICAL - Execute on ALL Nodes)

**WHERE:** All nodes
**WHEN:** Before Kubernetes installation
**WHY:** Kubernetes requires swap to be disabled for performance and reliability
**HOW:** Disable immediately and persist across reboots

```bash
# Disable swap immediately
swapoff -a

# Comment out swap entries in /etc/fstab to persist across reboots
sed -i '/ swap / s/^/#/' /etc/fstab

# Verify swap is disabled (should show 0)
free -h | grep Swap
```

**WHAT THIS DOES:**
- `swapoff -a`: Disables all swap immediately
- `sed -i '/ swap / s/^/#/' /etc/fstab`: Comments out swap entries in fstab
  - `-i`: Edit file in-place
  - `'/ swap /'`: Pattern to match lines containing " swap "
  - `s/^/#/`: Substitute beginning of line with # (comment)
- `free -h`: Display memory usage in human-readable format

**CRITICAL:** If swap is not disabled, kubelet will fail to start.

### 2.4 Enable Required Kernel Modules (Execute on ALL Nodes)

**WHERE:** All nodes
**WHEN:** Before container runtime installation
**WHY:** Container networking requires specific kernel modules
**HOW:** Load modules and persist across reboots

```bash
# Load modules immediately
modprobe overlay
modprobe br_netfilter

# Create config file to load modules at boot
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# Verify modules are loaded
lsmod | grep overlay
lsmod | grep br_netfilter
```

**WHAT THIS DOES:**
- `overlay`: Enables OverlayFS for container image layers
- `br_netfilter`: Enables iptables to see bridged traffic (required for pod networking)
- `/etc/modules-load.d/k8s.conf`: systemd loads these modules at boot

### 2.5 Configure Kernel Parameters (Execute on ALL Nodes)

**WHERE:** All nodes
**WHEN:** Before container runtime installation
**WHY:** Required for proper Kubernetes networking
**HOW:** Set sysctl parameters

```bash
# Create sysctl configuration
cat <<EOF | tee /etc/sysctl.d/k8s.conf
# Enable IP forwarding (required for pod networking)
net.ipv4.ip_forward = 1

# Enable bridge netfilter (required for iptables to see bridged traffic)
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# Increase connection tracking table size (for high connection count)
net.netfilter.nf_conntrack_max = 1000000

# Disable IPv6 if not used (optional, reduces attack surface)
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
EOF

# Apply settings immediately
sysctl --system

# Verify settings
sysctl net.ipv4.ip_forward
sysctl net.bridge.bridge-nf-call-iptables
```

**WHAT EACH PARAMETER DOES:**
- `net.ipv4.ip_forward = 1`: Allows Linux to forward packets between interfaces (required for pod-to-pod communication)
- `net.bridge.bridge-nf-call-iptables = 1`: Ensures iptables rules apply to bridge traffic
- `net.bridge.bridge-nf-call-ip6tables = 1`: Same for IPv6
- `net.netfilter.nf_conntrack_max`: Increases connection tracking table size (default too small for production)

---

## 3. System Configuration (All Nodes)

### 3.1 Configure NTP Time Synchronization

**WHERE:** All nodes
**WHEN:** Before Kubernetes installation
**WHY:** Time synchronization critical for distributed systems (etcd, certificates, logs)
**HOW:** Install and configure chrony

```bash
# Install chrony
apt-get install -y chrony

# Configure chrony to use OVH NTP servers (or your preferred NTP servers)
cat <<EOF > /etc/chrony/chrony.conf
# OVH NTP servers
server ntp.ovh.net iburst
server 0.debian.pool.ntp.org iburst
server 1.debian.pool.ntp.org iburst

# Allow chronyc to access from localhost
bindcmdaddress 127.0.0.1
bindcmdaddress ::1

# Allow large time corrections on startup
makestep 1.0 3

# Log clock adjustments
logdir /var/log/chrony
log measurements statistics tracking
EOF

# Restart chrony
systemctl restart chrony

# Enable chrony to start at boot
systemctl enable chrony

# Verify time synchronization
chronyc sources -v
chronyc tracking
```

**VERIFICATION:**
```bash
# Check system time
timedatectl status

# Should show:
# System clock synchronized: yes
# NTP service: active
```

**CRITICAL:** Time skew > will cause certificate validation failures.

---

## 4. Container Runtime Installation

Kubernetes requires a container runtime. We'll use **containerd** (recommended for production).

### 4.1 Install containerd (Execute on ALL Nodes)

**WHERE:** All nodes
**WHEN:** After system configuration, before Kubernetes components
**WHY:** Kubernetes needs a container runtime to run pods
**HOW:** Install from Docker repository (newer version than Debian repos)

```bash
# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package list
apt-get update

# Install containerd
apt-get install -y containerd.io

# Verify installation
containerd --version
```

**WHAT THIS DOES:**
- Downloads Docker GPG key for package verification
- Adds Docker repository to apt sources
- Installs containerd (container runtime)

### 4.2 Configure containerd (Execute on ALL Nodes)

**WHERE:** All nodes
**WHEN:** Immediately after containerd installation
**WHY:** Default config doesn't enable SystemdCgroup (required by Kubernetes)
**HOW:** Generate and modify containerd config

```bash
# Create containerd config directory
mkdir -p /etc/containerd

# Generate default configuration
containerd config default | tee /etc/containerd/config.toml

# Enable SystemdCgroup (CRITICAL for Kubernetes)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Restart containerd to apply configuration
systemctl restart containerd

# Enable containerd to start at boot
systemctl enable containerd

# Verify containerd is running
systemctl status containerd
```

**CRITICAL CONFIGURATION:**
The `SystemdCgroup = true` setting is MANDATORY. Without it, kubelet will fail with cgroup errors.

**WHAT THIS DOES:**
- Generates default containerd configuration
- Modifies config to use systemd cgroup driver (matches kubelet)
- Ensures containerd starts on boot

---

## 5. Kubernetes Components Installation

### 5.1 Add Kubernetes Repository (Execute on ALL Nodes)

**WHERE:** All nodes
**WHEN:** After containerd installation
**WHY:** Official Kubernetes packages not in Debian repos
**HOW:** Add Google's Kubernetes repository

```bash
# Add Kubernetes GPG key
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes repository (v1.28 stable)
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

# Update package list
apt-get update
```

**NOTE:** We use v1.28 stable channel. Adjust version as needed.

### 5.2 Install Kubernetes Packages (Execute on ALL Nodes)

**WHERE:** All nodes
**WHEN:** After adding repository
**WHY:** Required components for Kubernetes cluster
**HOW:** Install kubelet, kubeadm, kubectl

```bash
# Install specific versions (recommended for production)
apt-get install -y \
    kubelet=1.28.5-1.1 \
    kubeadm=1.28.5-1.1 \
    kubectl=1.28.5-1.1

# Hold packages to prevent automatic upgrades
apt-mark hold kubelet kubeadm kubectl

# Verify installation
kubelet --version
kubeadm version
kubectl version --client
```

**WHAT EACH COMPONENT DOES:**
- **kubelet**: Agent that runs on each node, manages pods and containers
- **kubeadm**: Tool for bootstrapping Kubernetes clusters
- **kubectl**: Command-line tool for interacting with cluster

**WHY HOLD PACKAGES:**
Kubernetes upgrades must be done carefully with proper testing. Holding packages prevents accidental upgrades during `apt upgrade`.

**NOTE:** Specific version (1.28.5-1.1) ensures consistency across nodes.

---

## 6. Control Plane Initialization

### 6.1 Initialize First Control Plane Node (Execute ONLY on k8s-master-01)

**WHERE:** First control plane node (k8s-master-01)
**WHEN:** After all nodes have Kubernetes packages installed
**WHY:** Initializes Kubernetes cluster control plane
**HOW:** Use kubeadm init with specific configuration

```bash
# Define variables (adjust to your environment)
export CONTROL_PLANE_ENDPOINT="k8s-master-01:6443"  # Or load balancer if using HA control plane
export POD_NETWORK_CIDR="10.244.0.0/16"  # Calico default

# Initialize control plane
kubeadm init \
  --control-plane-endpoint="${CONTROL_PLANE_ENDPOINT}" \
  --upload-certs \
  --pod-network-cidr="${POD_NETWORK_CIDR}" \
  --apiserver-advertise-address=$(hostname -I | awk '{print $1}')
```

**COMMAND EXPLANATION:**
- `--control-plane-endpoint`: DNS name or IP:PORT for API server (important for HA)
- `--upload-certs`: Uploads certificates to cluster for additional control planes to join
- `--pod-network-cidr`: IP range for pod network (must match Calico configuration)
- `--apiserver-advertise-address`: IP address API server advertises (auto-detects if omitted)

**EXPECTED OUTPUT:**
```
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

You can now join any number of control-plane nodes running the following command on each as root:

  kubeadm join k8s-master-01:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash> \
    --control-plane --certificate-key <key>

You can now join any number of worker nodes by running the following on each as root:

kubeadm join k8s-master-01:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash>
```

**CRITICAL:** Save the join commands! You'll need them to add nodes.

### 6.2 Configure kubectl (Execute on k8s-master-01)

**WHERE:** First control plane node
**WHEN:** Immediately after kubeadm init
**WHY:** Allows kubectl to communicate with cluster
**HOW:** Copy admin config

```bash
# For root user
export KUBECONFIG=/etc/kubernetes/admin.conf

# For regular user (recommended)
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Verify cluster access
kubectl get nodes
kubectl cluster-info
```

**EXPECTED OUTPUT:**
```
NAME            STATUS     ROLES           AGE   VERSION
k8s-master-01   NotReady   control-plane   1m    v1.28.5
```

**NOTE:** Status is "NotReady" because network plugin not yet installed.

---
## 7. Worker Nodes Join

### 7.1 Join Worker Nodes to Cluster (REQUIRED)

**WHERE:** Each worker node (database, storage, application, call server nodes)
**WHEN:** After control plane is initialized
**HOW:** Use the kubeadm join command from section 6.1 output

```bash
# On each worker node, run the join command provided by kubeadm init
# Example:
kubeadm join k8s-master-01:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash>
```

**VERIFICATION:**

```bash
# On control plane node
kubectl get nodes

# Expected output:
# NAME            STATUS     ROLES           AGE   VERSION
# k8s-master-01   NotReady   control-plane   10m   v1.28.5
# k8s-db-01       NotReady   <none>          1m    v1.28.5
# k8s-db-02       NotReady   <none>          1m    v1.28.5
# ...
```

**NOTE:** Nodes show "NotReady" status until network plugin is installed (Section 8).

### 7.2 Join Additional Control Plane Nodes (REQUIRED for HA)

**WHERE:** Second and third control plane nodes (k8s-master-02, k8s-master-03)
**WHEN:** After first control plane is initialized
**HOW:** Use the control-plane join command from section 6.1 output

```bash
# On k8s-master-02 and k8s-master-03, run:
kubeadm join k8s-master-01:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash> \
    --control-plane --certificate-key <key>
```

**VERIFICATION:**

```bash
# On any control plane node
kubectl get nodes

# Expected output:
# NAME            STATUS     ROLES           AGE   VERSION
# k8s-master-01   NotReady   control-plane   15m   v1.28.5
# k8s-master-02   NotReady   control-plane   5m    v1.28.5
# k8s-master-03   NotReady   control-plane   5m    v1.28.5
```

### 7.3 Regenerate Join Tokens (If Needed)

**Tokens expire after 24 hours.** To generate new tokens:

```bash
# Generate new token for worker nodes
kubeadm token create --print-join-command

# Generate new token for control plane nodes
kubeadm init phase upload-certs --upload-certs
# This outputs a new --certificate-key

# Then create the full join command
kubeadm token create --print-join-command --certificate-key <new-key>
```

---

## 8. Network Plugin Installation

### 8.1 Install Calico Network Plugin (REQUIRED)

**WHERE:** First control plane node
**WHEN:** After all nodes have joined
**WHY:** Provides pod networking and NetworkPolicy support
**HOW:** Deploy Calico manifests

```bash
# Download Calico manifest
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/calico.yaml

# Review pod network CIDR (should match --pod-network-cidr from kubeadm init)
grep CALICO_IPV4POOL_CIDR calico.yaml
# Should show: value: "10.244.0.0/16"

# Apply Calico
kubectl apply -f calico.yaml

# Wait for Calico pods to be ready
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=300s
```

**VERIFICATION:**

```bash
# Check Calico pods are running
kubectl get pods -n kube-system | grep calico

# Expected output:
# calico-kube-controllers-xxx   1/1     Running   0          2m
# calico-node-xxx               1/1     Running   0          2m
# calico-node-yyy               1/1     Running   0          2m
# ...

# Check nodes are now Ready
kubectl get nodes

# Expected output:
# NAME            STATUS   ROLES           AGE   VERSION
# k8s-master-01   Ready    control-plane   20m   v1.28.5
# k8s-master-02   Ready    control-plane   10m   v1.28.5
# k8s-db-01       Ready    <none>          5m    v1.28.5
# ...
```

---

## 9. Storage Configuration

### 9.1 Label Nodes by Role (REQUIRED)

**WHERE:** First control plane node
**WHEN:** After all nodes are Ready
**WHY:** Pod scheduling requires node labels
**HOW:** Apply labels to each node

```bash
# Label database nodes
kubectl label nodes k8s-db-01 k8s-db-02 k8s-db-03 node-role=database

# Label storage nodes
kubectl label nodes k8s-storage-01 k8s-storage-02 k8s-storage-03 k8s-storage-04 node-role=storage

# Label application nodes
kubectl label nodes k8s-app-01 k8s-app-02 k8s-app-03 node-role=application

# Label call server nodes (if separate)
kubectl label nodes k8s-call-01 k8s-call-02 livekit=true coturn=true

# Verify labels
kubectl get nodes --show-labels
```

### 9.2 Install Local Path Provisioner (RECOMMENDED)

**WHERE:** First control plane node
**WHEN:** After node labeling
**WHY:** Provides dynamic local storage provisioning
**HOW:** Deploy local-path-provisioner

```bash
# Deploy local-path-provisioner
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml

# Verify deployment
kubectl get pods -n local-path-storage

# Expected output:
# NAME                                     READY   STATUS    RESTARTS   AGE
# local-path-provisioner-xxx               1/1     Running   0          30s

# Verify StorageClass
kubectl get storageclass

# Expected output:
# NAME         PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
# local-path   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  1m
```

**NOTE:** For production, you may also want to configure additional storage classes for specific workloads.

---

## 10. Validation and Testing

### 10.1 Verify Cluster Health (REQUIRED)

```bash
# Check all nodes are Ready
kubectl get nodes

# Check all system pods are Running
kubectl get pods -n kube-system

# Check cluster info
kubectl cluster-info

# Expected output:
# Kubernetes control plane is running at https://k8s-master-01:6443
# CoreDNS is running at https://k8s-master-01:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

### 10.2 Test Pod Deployment (REQUIRED)

```bash
# Create test deployment
kubectl create deployment nginx --image=nginx:alpine

# Expose deployment
kubectl expose deployment nginx --port=80 --type=NodePort

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod -l app=nginx --timeout=120s

# Check deployment
kubectl get pods -l app=nginx

# Get service details
kubectl get svc nginx

# Test connectivity (from any node)
NODE_PORT=$(kubectl get svc nginx -o jsonpath='{.spec.ports[0].nodePort}')
curl http://localhost:$NODE_PORT

# Expected: nginx welcome page HTML

# Cleanup
kubectl delete deployment nginx
kubectl delete svc nginx
```

### 10.3 Test DNS Resolution (REQUIRED)

```bash
# Deploy test pod
kubectl run test-dns --image=busybox:latest --restart=Never -- sleep 3600

# Wait for pod
kubectl wait --for=condition=Ready pod/test-dns --timeout=60s

# Test DNS lookup
kubectl exec test-dns -- nslookup kubernetes.default

# Expected output showing successful DNS resolution

# Cleanup
kubectl delete pod test-dns
```

### 10.4 Test Inter-Node Communication (REQUIRED)

```bash
# Create deployment with 2 replicas on different nodes
kubectl create deployment multi-node-test --image=nginx:alpine --replicas=2

# Wait for pods
kubectl wait --for=condition=Ready pods -l app=multi-node-test --timeout=120s

# Check pods are on different nodes
kubectl get pods -l app=multi-node-test -o wide

# Cleanup
kubectl delete deployment multi-node-test
```

---

## 11. Troubleshooting

### 11.1 Common Issues

#### Issue: Node stuck in "NotReady" state

**Symptoms:**
```
kubectl get nodes
NAME            STATUS     ROLES           AGE   VERSION
k8s-master-01   NotReady   control-plane   10m   v1.28.5
```

**Solutions:**
1. Check kubelet status:
   ```bash
   systemctl status kubelet
   journalctl -u kubelet -n 50
   ```

2. Check network plugin is installed:
   ```bash
   kubectl get pods -n kube-system | grep calico
   ```

3. Check for firewall blocking required ports:
   ```bash
   iptables -L -n | grep 10250
   ```

#### Issue: Pods stuck in "Pending" state

**Symptoms:**
```
kubectl get pods
NAME          READY   STATUS    RESTARTS   AGE
test-pod      0/1     Pending   0          5m
```

**Solutions:**
1. Check for resource constraints:
   ```bash
   kubectl describe pod <pod-name>
   ```

2. Check node labels match pod nodeSelector:
   ```bash
   kubectl get nodes --show-labels
   ```

3. Check for tainted nodes:
   ```bash
   kubectl describe nodes | grep -i taint
   ```

#### Issue: kubeadm join fails

**Symptoms:**
```
error execution phase preflight: couldn't validate the identity of the API Server
```

**Solutions:**
1. Token may have expired (tokens expire after 24 hours):
   ```bash
   # On control plane, generate new token
   kubeadm token create --print-join-command
   ```

2. Check control plane is accessible:
   ```bash
   telnet <control-plane-ip> 6443
   ```

3. Check /etc/hosts has correct control plane hostname:
   ```bash
   cat /etc/hosts | grep k8s-master
   ```

#### Issue: CoreDNS pods CrashLoopBackOff

**Symptoms:**
```
kubectl get pods -n kube-system | grep coredns
coredns-xxx   0/1     CrashLoopBackOff   5          10m
```

**Solutions:**
1. Check for loop in /etc/resolv.conf:
   ```bash
   kubectl exec -n kube-system <coredns-pod> -- cat /etc/resolv.conf
   ```

2. If nameserver is 127.0.0.1 or loop detected, edit CoreDNS ConfigMap:
   ```bash
   kubectl edit configmap coredns -n kube-system
   # Remove or modify the forward plugin
   ```

3. Restart CoreDNS pods:
   ```bash
   kubectl rollout restart deployment coredns -n kube-system
   ```

#### Issue: Calico pods not starting

**Symptoms:**
```
kubectl get pods -n kube-system | grep calico
calico-node-xxx   0/1     Init:0/3   0          5m
```

**Solutions:**
1. Check pod network CIDR matches:
   ```bash
   kubectl cluster-info dump | grep -i cidr
   kubectl get configmap -n kube-system calico-config -o yaml
   ```

2. Check kernel modules are loaded:
   ```bash
   lsmod | grep -E 'br_netfilter|overlay'
   ```

3. Check Calico logs:
   ```bash
   kubectl logs -n kube-system <calico-pod> -c calico-node
   ```

### 11.2 Diagnostic Commands

**Check cluster health:**
```bash
kubectl get --raw='/readyz?verbose'
kubectl get cs  # component status (deprecated but useful)
```

**Check certificate expiration:**
```bash
kubeadm certs check-expiration
```

**Check etcd health:**
```bash
kubectl exec -n kube-system etcd-k8s-master-01 -- sh -c "ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health"
```

**Check API server logs:**
```bash
kubectl logs -n kube-system kube-apiserver-k8s-master-01
```

---

## Summary

You have now:
- Configured all nodes with required system settings
- Installed and configured containerd
- Installed Kubernetes components
- Initialized control plane (HA with 3 masters)
- Joined all worker nodes
- Installed Calico network plugin
- Configured storage
- Validated cluster health

**Next Steps:**
1. Proceed to Matrix/Synapse deployment
2. Install Helm charts
3. Deploy infrastructure components (PostgreSQL, Redis, MinIO)

---
