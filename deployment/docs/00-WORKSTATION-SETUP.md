# Workstation Setup for Matrix/Synapse Deployment

**Purpose:** Install and configure client tools on your local workstation to manage the Kubernetes cluster
**Applies to:** Your laptop/desktop computer (NOT the Kubernetes nodes)
**Supported OS:** Linux, macOS, Windows (WSL2)
**Time Required:** 15-30 minutes

---

## Overview

Before deploying Matrix/Synapse, you need to install tools on your **local workstation** (your laptop/desktop) to manage the Kubernetes cluster remotely.

**Required Tools:**
1. **kubectl** - Kubernetes command-line tool
2. **helm** - Kubernetes package manager
3. **git** - Version control (to clone this repository)
4. **SSH client** - To access Kubernetes nodes (usually pre-installed)

**What This Guide Does NOT Cover:**
- Installing Kubernetes on the VMs (see `00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md`)
- Installing anything on the Kubernetes nodes themselves

---

## Table of Contents

1. [Linux Workstation Setup](#1-linux-workstation-setup)
2. [macOS Workstation Setup](#2-macos-workstation-setup)
3. [Windows Workstation Setup (WSL2)](#3-windows-workstation-setup-wsl2)
4. [Configure kubectl Access](#4-configure-kubectl-access)
5. [Verify Installation](#5-verify-installation)

---

## 1. Linux Workstation Setup

### 1.1 Install kubectl (Linux)

**Option A: Using Native Package Manager (Recommended)**

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

### 1.2 Install Helm (Linux)

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

### 1.3 Install Git (Linux)

```bash
# Debian/Ubuntu
sudo apt-get update
sudo apt-get install -y git

# Verify installation
git --version
```

---

## 2. macOS Workstation Setup

### 2.1 Install Homebrew (if not already installed)

```bash
# Install Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Add Homebrew to PATH (if needed)
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

### 2.2 Install kubectl (macOS)

```bash
# Install kubectl using Homebrew
brew install kubectl

# Verify installation
kubectl version --client
```

**Alternative: Manual Installation**

```bash
# Download kubectl binary
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"

# Make executable
chmod +x kubectl

# Move to PATH
sudo mv kubectl /usr/local/bin/

# Verify installation
kubectl version --client
```

### 2.3 Install Helm (macOS)

```bash
# Install Helm using Homebrew
brew install helm

# Verify installation
helm version
```

### 2.4 Install Git (macOS)

```bash
# Git is usually pre-installed on macOS, verify:
git --version

# If not installed, install via Homebrew:
brew install git
```

---

## 3. Windows Workstation Setup (WSL2)

**Note:** For Windows, we strongly recommend using WSL2 (Windows Subsystem for Linux) for the best experience.

### 3.1 Install WSL2

```powershell
# Open PowerShell as Administrator and run:
wsl --install

# Reboot your computer
# After reboot, WSL2 will complete installation

# Install Ubuntu (recommended distribution)
wsl --install -d Ubuntu

# Launch Ubuntu
wsl
```

### 3.2 Install kubectl in WSL2

Once in WSL2 Ubuntu terminal, follow the Linux instructions above:

```bash
# Add Kubernetes repository
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install kubectl
sudo apt-get update
sudo apt-get install -y kubectl

# Verify
kubectl version --client
```

### 3.3 Install Helm in WSL2

```bash
# Install Helm using script
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version
```

### 3.4 Install Git in WSL2

```bash
# Update package list
sudo apt-get update

# Install git
sudo apt-get install -y git

# Verify
git --version
```

---

## 4. Configure kubectl Access

After your Kubernetes cluster is initialized (following `00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md`), you need to configure kubectl on your workstation to access it.

### 4.1 Copy kubeconfig from Control Plane

**On the Kubernetes control plane node (k8s-master-01):**

```bash
# Display the kubeconfig file content
cat ~/.kube/config
```

**On your workstation:**

```bash
# Create .kube directory
mkdir -p ~/.kube

# Option 1: Copy via SCP
scp root@k8s-master-01-ip:~/.kube/config ~/.kube/config

# Option 2: Manually create and paste
nano ~/.kube/config
# Paste the content from the control plane
# Save and exit (Ctrl+X, Y, Enter)

# Set proper permissions
chmod 600 ~/.kube/config
```

### 4.2 Update Server Address (If Needed)

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

### 4.3 Verify kubectl Access

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

## 5. Verify Installation

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

## Next Steps

After completing workstation setup:

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
   - Follow `docs/00-KUBERNETES-INSTALLATION-DEBIAN-OVH.md` to set up cluster on your VMs
   - Return here to configure kubectl access (Section 4)

4. ✅ **If Kubernetes cluster already installed:**
   - Configure kubectl access (Section 4 above)
   - Proceed to `docs/DEPLOYMENT-GUIDE.md` to deploy Matrix/Synapse

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
- ✅ kubectl installed on your workstation
- ✅ helm installed on your workstation
- ✅ git installed on your workstation
- ✅ kubectl configured to access your Kubernetes cluster
- ✅ Verified connectivity to the cluster

**Next:** Proceed to deploying Matrix/Synapse using `docs/DEPLOYMENT-GUIDE.md`

---

**Document Version:** 1.0
**Last Updated:** 2025-11-11
**Tested On:** Ubuntu 22.04, macOS 14.0, Windows 11 WSL2
