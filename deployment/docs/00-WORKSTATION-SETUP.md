# Management Node Setup for Matrix/Synapse Deployment

## What Is This Document For?

This document sets up the **management node** - the machine from which you will **control and manage** the Kubernetes cluster.

### Understanding the Management Node

**The management node is the machine where you run commands like:**
- `kubectl get pods` - Check what's running
- `kubectl apply -f deployment/` - Deploy applications
- `helm install prometheus ...` - Install software packages

**This machine needs network access to the Kubernetes API server but is NOT part of the cluster itself.**

---

## Choosing Your Management Node

**You have several options:**

### Option 1: Dedicated Management Server (RECOMMENDED for Production)
- A separate server/VM provided by the customer
- Used only for cluster management
- Keeps management traffic separate from cluster workload
- **Example**: Bastion host, jump server, or dedicated ops server

### Option 2: Kubernetes Control-Plane Node
- Install tools directly on one of the Kubernetes master nodes
- Simpler - no additional machine needed
- **Tradeoff**: Management tools run on cluster infrastructure

### Option 3: Operator's Workstation
- Your local laptop/desktop
- Manage cluster remotely over network
- **Requires**: VPN or network access to customer infrastructure

---

## What This Guide Does

**Installs on the MANAGEMENT NODE (not on Kubernetes worker/master nodes):**

1. **kubectl** - Command-line tool to control Kubernetes (REQUIRED)
2. **helm** - Package manager to install applications on Kubernetes (REQUIRED)
3. **git** - Version control to clone this repository (REQUIRED)
4. **SSH client** - To access Kubernetes nodes if needed (usually pre-installed, REQUIRED)

**After setup, this machine becomes your "control center" where:**
- You run all deployment commands
- You monitor cluster status
- You perform updates and maintenance
- Customer's IT team operates the cluster from here

---

## What This Guide Does NOT Cover

- Installing Kubernetes on the cluster nodes (see `00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md`)
- Installing anything on the actual Kubernetes master/worker nodes
- Configuring the Kubernetes cluster itself

---

## Supported Operating Systems

**This guide covers Linux (Debian/Ubuntu) only.**

Your management node should be running Debian 11/12 or Ubuntu 20.04/22.04 LTS.

---

## Table of Contents

1. [Install Required Tools](#1-install-required-tools)
2. [Configure kubectl Access](#2-configure-kubectl-access)
3. [Verify Installation](#3-verify-installation)
4. [Next Steps](#4-next-steps)

---

## 1. Install Required Tools

### 1.1 Install kubectl - REQUIRED

**Option A: Using Native Package Manager (RECOMMENDED)**

```bash
# Add Kubernetes GPG key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes repository
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install kubectl
sudo apt-get update
sudo apt-get install -y kubectl

# Verify installation
kubectl version --client
```

**Option B: Using Binary Download**

```bash
# Download latest kubectl binary
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# Make executable
chmod +x kubectl

# Move to PATH
sudo mv kubectl /usr/local/bin/

# Verify installation
kubectl version --client
```

### 1.2 Install Helm (Linux) - REQUIRED

**Option A: Using Install Script (Recommended)**

```bash
# Download and run Helm install script
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify installation
helm version
```

**Option B: Using Package Manager**

```bash
# Debian/Ubuntu using Snapcraft
sudo snap install helm --classic

# Or using binary download
curl -LO https://get.helm.sh/helm-v3.13.0-linux-amd64.tar.gz
tar -zxvf helm-v3.13.0-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm
rm -rf linux-amd64 helm-v3.13.0-linux-amd64.tar.gz

# Verify installation
helm version
```

### 1.3 Install Git (Linux) - REQUIRED

```bash
# Debian/Ubuntu
sudo apt-get update
sudo apt-get install -y git

# Verify installation
git --version
```

---

## 2. Configure kubectl Access

After your Kubernetes cluster is initialized (following `00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md`), you need to configure kubectl on your **management node** to access the cluster.

### 2.1 Copy kubeconfig from Control Plane

**If your management node IS the control-plane node:**
```bash
# Kubeconfig is already available at:
cat ~/.kube/config
# No copying needed - kubectl will work immediately
```

**If your management node IS NOT the control-plane node:**

**On the Kubernetes control plane node:**

```bash
# Display the kubeconfig file content
sudo cat /etc/kubernetes/admin.conf
```

**On your management node:**

```bash
# Create .kube directory
mkdir -p ~/.kube

# Option 1: Copy via SCP
scp root@<control-plane-ip>:/etc/kubernetes/admin.conf ~/.kube/config

# Option 2: Manually create and paste
nano ~/.kube/config
# Paste the content from the control plane
# Save and exit (Ctrl+X, Y, Enter)

# Set proper permissions
chmod 600 ~/.kube/config
```

### 2.2 Update Server Address (If Needed)

If your control plane nodes are behind NAT or have different external IPs:

```bash
# Edit kubeconfig
nano ~/.kube/config

# Find this line:
#   server: https://192.168.0.10:6443
# Replace 192.168.0.10 with the public IP or hostname you use to access the control plane

# Example:
#   server: https://k8s.example.com:6443
# or
#   server: https://203.0.113.10:6443
```

### 2.3 Verify kubectl Access

```bash
# Test connection to cluster
kubectl cluster-info

# Expected output:
# Kubernetes control plane is running at https://...
# CoreDNS is running at https://...

# List nodes
kubectl get nodes

# Expected output (example for 100 CCU scale):
# NAME            STATUS   ROLES           AGE   VERSION
# k8s-master-01   Ready    control-plane   10m   v1.28.x
# k8s-master-02   Ready    control-plane   9m    v1.28.x
# k8s-master-03   Ready    control-plane   9m    v1.28.x
# k8s-db-01       Ready    <none>          8m    v1.28.x
# k8s-db-02       Ready    <none>          8m    v1.28.x
# k8s-db-03       Ready    <none>          8m    v1.28.x
# ...

# List namespaces
kubectl get namespaces

# Expected output:
# NAME              STATUS   AGE
# default           Active   10m
# kube-node-lease   Active   10m
# kube-public       Active   10m
# kube-system       Active   10m
```

---

## 3. Verify Installation

Run these commands to verify everything is installed correctly:

```bash
# Check kubectl version
kubectl version --client
# Expected: Client Version: v1.28.x or higher

# Check Helm version
helm version
# Expected: version.BuildInfo{Version:"v3.13.x" or higher}

# Check git version
git --version
# Expected: git version 2.x.x or higher

# Check SSH connectivity to a control plane node
ssh root@k8s-master-01-ip "echo 'SSH connection successful'"
# Expected: SSH connection successful

# Test kubectl access (requires cluster to be set up)
kubectl get nodes
# Expected: List of nodes with STATUS=Ready
```

---

## Common Issues and Solutions

### Issue: kubectl connection refused

**Symptoms:**
```
The connection to the server <ip>:6443 was refused
```

**Solutions:**
1. Ensure Kubernetes cluster is fully initialized
2. Check firewall allows port 6443 from your IP
3. Verify server address in `~/.kube/config` is correct
4. Check control plane nodes are running: `ssh root@k8s-master-01 "kubectl get nodes"`

### Issue: kubectl certificate errors

**Symptoms:**
```
x509: certificate signed by unknown authority
```

**Solutions:**
1. Re-copy kubeconfig from control plane (may have been regenerated)
2. Ensure you copied the entire kubeconfig file including certificates
3. Check certificate expiration: `kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d | openssl x509 -text | grep -A 2 Validity`

### Issue: Helm command not found

**Solution:**
```bash
# Verify Helm binary location
which helm

# If not found, add to PATH
echo 'export PATH=$PATH:/usr/local/bin' >> ~/.bashrc
source ~/.bashrc
```

### Issue: Permission denied when running kubectl

**Solutions:**
```bash
# Fix kubeconfig permissions
chmod 600 ~/.kube/config

# Ensure ownership
chown $USER:$USER ~/.kube/config
```

---

## 4. Next Steps

After completing management node setup:

1. ✅ **Verify all tools installed:**
   ```bash
   kubectl version --client && helm version && git --version
   ```

2. ✅ **Clone this repository:**
   ```bash
   git clone https://github.com/your-org/Messenger.git
   cd Messenger/deployment
   ```

3. ✅ **If Kubernetes cluster not yet installed:**
   - Follow `docs/00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md` to set up cluster on customer servers
   - Return here to configure kubectl access (Section 4)

4. ✅ **If Kubernetes cluster already installed:**
   - Configure kubectl access (Section 4 above)
   - Proceed to main `README.md` to deploy Matrix/Synapse

---

## Reference: Tool Versions

**Recommended Versions (as of 2025-11-11):**

| Tool | Minimum Version | Recommended Version | Notes |
|------|----------------|---------------------|-------|
| kubectl | 1.27.0 | 1.28.5 | Should match cluster version ±1 minor version |
| helm | 3.12.0 | 3.13.0 | Helm 3.x required (NOT Helm 2.x) |
| git | 2.20.0 | 2.40.0+ | Any recent version |
| SSH client | - | OpenSSH 8.0+ | Usually pre-installed |

**Check versions:**
```bash
kubectl version --client --short
helm version --short
git --version
ssh -V
```

---

## Troubleshooting Tips

### Enable kubectl command completion (Optional but helpful)

**Bash:**
```bash
echo 'source <(kubectl completion bash)' >> ~/.bashrc
source ~/.bashrc
```

**Zsh:**
```bash
echo 'source <(kubectl completion zsh)' >> ~/.zshrc
source ~/.zshrc
```

### Set kubectl alias (Optional)

```bash
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc
source ~/.bashrc

# Now you can use 'k' instead of 'kubectl'
k get nodes
```

### Helm autocomplete (Optional)

```bash
echo 'source <(helm completion bash)' >> ~/.bashrc
source ~/.bashrc
```

---

## Summary

You should now have:
- ✅ kubectl installed on your management node
- ✅ helm installed on your management node
- ✅ git installed on your management node
- ✅ kubectl configured to access your Kubernetes cluster
- ✅ Verified connectivity to the cluster

**Your management node is now ready to deploy and manage Matrix/Synapse on the Kubernetes cluster.**

**Next:** Proceed to the main `README.md` for complete deployment instructions

---


