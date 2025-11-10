# Antivirus Disable Guide: Complete Instructions
## How to Deploy Without Antivirus Scanning - Risks, Alternatives, and Implementation

**Purpose:** Comprehensive guide for organizations choosing to deploy Matrix/Synapse WITHOUT antivirus scanning.

**Target Audience:** Organizations with trusted user bases, budget constraints, or complexity concerns.

**Last Updated:** November 10, 2025
**Document Version:** 1.0

---

## Table of Contents

1. [Executive Decision Framework](#1-executive-decision-framework)
2. [When to Disable Antivirus](#2-when-to-disable-antivirus)
3. [Risks and Trade-offs](#3-risks-and-trade-offs)
4. [Alternative Security Measures](#4-alternative-security-measures)
5. [Implementation: Deploying Without AV](#5-implementation-deploying-without-av)
6. [Monitoring and Detection](#6-monitoring-and-detection)
7. [Incident Response Without AV](#7-incident-response-without-av)
8. [Re-enabling Antivirus Later](#8-re-enabling-antivirus-later)

---

## 1. Executive Decision Framework

### 1.1 Quick Decision Matrix

Use this matrix to determine if disabling antivirus is appropriate for your organization:

| Criterion | Disable AV | Keep AV |
|-----------|-----------|---------|
| **User Base** | <100 trusted internal users | >100 users or external users |
| **Budget** | Limited (<$200/month for AV infra) | Adequate (>$200/month available) |
| **Risk Tolerance** | High (can accept malware risk) | Low (must prevent malware) |
| **Operational Capacity** | Limited (no dedicated team) | Adequate (ops team available) |
| **Compliance** | No regulatory requirements | HIPAA, PCI-DSS, or similar |
| **File Types** | Mostly text/images | Executables, archives allowed |
| **User Trust** | Employees only, educated users | Public, unknown users |
| **Liability** | Internal risk acceptable | Customer data, legal exposure |

**Scoring:**
- **6-8 "Disable AV":** Disabling antivirus is **reasonable**
- **3-5 mixed:** **Re-evaluate trade-offs** carefully
- **0-2 "Disable AV":** Antivirus is **strongly recommended**

### 1.2 Cost-Benefit Analysis

**Cost of Running Antivirus:**
- **Infrastructure:** $150-250/month (10-20 vCPU, 24Gi RAM)
- **Operational:** 2-4 hours/month (monitoring, updates, incident response)
- **Complexity:** Moderate (queue management, ClamAV updates, false positives)
- **Development:** Included in deployment (spam-checker module, workers)

**Cost of Malware Incident:**
- **Data Breach:** $50,000 - $500,000+ (IBM average: $4.24M)
- **Downtime:** $5,000 - $50,000/hour (depending on size)
- **Reputation:** Difficult to quantify, potentially severe
- **Legal:** Fines, lawsuits, regulatory penalties
- **Recovery:** 100+ hours of emergency work

**ROI Calculation:**
```
Annual AV Cost = $250/month × 12 = $3,000
Break-even = 1 prevented incident worth >$3,000

Even ONE prevented malware incident per year justifies the cost.
```

**However:**
If malware risk is genuinely low (small internal deployment), cost may not be justified.

---

## 2. When to Disable Antivirus

### 2.1 Acceptable Use Cases

**✅ Internal Company Deployment (<100 employees)**
- **Rationale:** Trusted user base, controlled environment
- **Mitigations:** User education, endpoint antivirus on devices
- **Risk Level:** Low

**✅ Proof-of-Concept / Staging Environment**
- **Rationale:** Non-production, temporary deployment
- **Mitigations:** Network isolation, no sensitive data
- **Risk Level:** Minimal

**✅ Read-Only Archive / Historical Data**
- **Rationale:** No new uploads, legacy data only
- **Mitigations:** Archive malware-scanned elsewhere first
- **Risk Level:** Low (if pre-scanned)

**✅ Development / Testing Environment**
- **Rationale:** No real users, test data only
- **Mitigations:** Isolated network, no production data
- **Risk Level:** Minimal

**✅ Budget-Constrained Non-Profit / Education**
- **Rationale:** Limited budget, non-critical use
- **Mitigations:** Strict file policies, user training
- **Risk Level:** Medium (accepted trade-off)

### 2.2 Unacceptable Use Cases

**❌ Public-Facing Deployment**
- **Reason:** Unknown users, high attack surface
- **Alternative:** MUST implement antivirus or strict file filtering

**❌ Healthcare / Medical Data**
- **Reason:** HIPAA compliance requires malware protection
- **Alternative:** No acceptable alternative - AV required

**❌ Financial Services**
- **Reason:** PCI-DSS, regulatory requirements
- **Alternative:** No acceptable alternative - AV required

**❌ Customer-Facing SaaS**
- **Reason:** Legal liability, customer trust
- **Alternative:** No acceptable alternative - AV required

**❌ Government / Defense**
- **Reason:** Security clearance, classified data
- **Alternative:** May require even more than ClamAV (enterprise AV)

**❌ Large Enterprise (>1000 users)**
- **Reason:** Statistical probability of malware increases with scale
- **Alternative:** Antivirus is cost-effective at this scale

---

## 3. Risks and Trade-offs

### 3.1 Security Risks

**Risk 1: Malware Propagation**
- **Threat:** User uploads infected file
- **Impact:** Other users download and execute malware
- **Likelihood:** Medium (depends on user base)
- **Consequence:** Data theft, ransomware, system compromise

**Mitigation (Partial):**
- Endpoint antivirus on user devices (client-side protection)
- File type restrictions (block executables)
- User education and awareness training

**Risk 2: Ransomware**
- **Threat:** Encrypted malware uploaded, spreads when downloaded
- **Impact:** Systems encrypted, data held for ransom
- **Likelihood:** Low (requires user to execute file)
- **Consequence:** Severe (downtime, data loss)

**Mitigation:**
- Backups (can restore without paying ransom)
- Network segmentation (limit spread)
- User education (don't execute unknown files)

**Risk 3: Data Exfiltration**
- **Threat:** Trojan disguised as legitimate file
- **Impact:** Stolen credentials, corporate espionage
- **Likelihood:** Medium (if targeted)
- **Consequence:** Severe (data breach)

**Mitigation:**
- DLP (Data Loss Prevention) tools
- Network monitoring for suspicious outbound traffic
- Least privilege access controls

**Risk 4: Legal Liability**
- **Threat:** Your server used to distribute malware
- **Impact:** Lawsuits, regulatory fines
- **Likelihood:** Low (if user base trusted)
- **Consequence:** Severe (financial + reputation)

**Mitigation:**
- Terms of Service disclaimer
- User agreements prohibiting malware
- Logging and audit trail

### 3.2 Operational Risks

**Risk 5: Storage Abuse**
- **Threat:** Malware uses storage space (worms, disk fillers)
- **Impact:** Storage quota exhausted
- **Likelihood:** Low
- **Consequence:** Moderate (denial of service)

**Mitigation:**
- Storage quotas per user
- Monitoring storage growth
- Automated cleanup policies

**Risk 6: False Sense of Security**
- **Threat:** Users assume all files are safe
- **Impact:** Reduced vigilance
- **Likelihood:** Medium
- **Consequence:** Increased infection rate

**Mitigation:**
- Clear messaging: "No automatic scanning - be careful with downloads"
- User training emphasizing personal responsibility

### 3.3 Comparison Table

| Aspect | With Antivirus | Without Antivirus |
|--------|---------------|-------------------|
| **Security Level** | High (90-95% detection) | Low (0% automated detection) |
| **Cost** | $150-250/month | $0 extra |
| **Complexity** | High | Low |
| **Upload UX** | Fast (async scanning) | Fast |
| **False Positives** | Yes (rare, ~0.1%) | No |
| **Zero-Day Protection** | No (signature-based) | No |
| **Compliance** | Better | May fail audits |
| **Operational Burden** | Medium | Low |
| **Legal Liability** | Lower | Higher |
| **User Education Required** | Moderate | High |

---

## 4. Alternative Security Measures

If you disable antivirus, you MUST implement compensating controls:

### 4.1 File Type Whitelist (MANDATORY)

**Concept:** Only allow safe file types

**Implementation: Synapse Spam-Checker Module**

```python
# file_type_whitelist_checker.py

import mimetypes
from synapse.module_api import ModuleApi
from synapse.module_api.errors import Codes

ALLOWED_MIME_TYPES = {
    # Images
    'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/svg+xml',
    # Documents
    'application/pdf', 'text/plain', 'text/markdown',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',  # docx
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',  # xlsx
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',  # pptx
    'application/vnd.oasis.opendocument.text',  # odt
    'application/vnd.oasis.opendocument.spreadsheet',  # ods
    # Audio/Video
    'audio/mpeg', 'audio/ogg', 'audio/wav',
    'video/mp4', 'video/webm', 'video/ogg',
    # Archives (RISKY - consider disabling)
    # 'application/zip', 'application/x-tar', 'application/gzip',
}

BLOCKED_EXTENSIONS = {
    # Executables
    '.exe', '.bat', '.cmd', '.com', '.msi', '.scr',
    # Scripts
    '.sh', '.bash', '.ps1', '.vbs', '.js',
    # Mobile
    '.apk', '.ipa',
    # Mac
    '.app', '.dmg', '.pkg',
    # Linux
    '.deb', '.rpm', '.run',
    # Other dangerous
    '.dll', '.so', '.dylib',
}

class FileTypeWhitelistChecker:
    def __init__(self, config: dict, api: ModuleApi):
        self.api = api
        self.logger = api.logger

    async def check_media_file_for_spam(self, file_wrapper, file_info):
        """
        Check if uploaded file type is allowed.
        """
        upload_name = file_info.get("upload_name", "")
        content_type = file_info.get("content_type", "")

        # Check extension
        if any(upload_name.lower().endswith(ext) for ext in BLOCKED_EXTENSIONS):
            self.logger.warn(f"Blocked file with dangerous extension: {upload_name}")
            return Codes.FORBIDDEN

        # Check MIME type
        if content_type and content_type not in ALLOWED_MIME_TYPES:
            # Try to guess MIME type from filename
            guessed_type, _ = mimetypes.guess_type(upload_name)
            if guessed_type not in ALLOWED_MIME_TYPES:
                self.logger.warn(f"Blocked file with disallowed MIME type: {content_type} ({upload_name})")
                return Codes.FORBIDDEN

        # File type is allowed
        return Codes.NOT_SPAM


def parse_config(config: dict) -> dict:
    return config


def create_module(config: dict, api: ModuleApi):
    return FileTypeWhitelistChecker(config, api)
```

**Deployment:**

```yaml
# In homeserver.yaml
modules:
  - module: file_type_whitelist_checker.FileTypeWhitelistChecker
    config: {}
```

**User Impact:**
- ✅ Blocks executables, scripts, dangerous files
- ⚠️ May block legitimate files (e.g., software distributions)
- ℹ️ Users see "Upload failed - file type not allowed"

### 4.2 File Size Limits (MANDATORY)

**Concept:** Limit uploaded file size

**Implementation: Synapse Configuration**

```yaml
# In homeserver.yaml
max_upload_size: "100M"  # 100 megabytes maximum

# For different limits per user (requires custom module)
# - Free users: 10MB
# - Premium users: 100MB
```

**Rationale:**
- Limits storage abuse
- Reduces risk of large malware payloads
- Improves performance (smaller files scan faster IF you add AV later)

### 4.3 Upload Rate Limiting (HIGHLY RECOMMENDED)

**Concept:** Limit how many files a user can upload per time period

**Implementation: Synapse Configuration**

```yaml
# In homeserver.yaml
rc_message:
  per_second: 10
  burst_count: 50

# Custom rate limit for media uploads
# (Requires Synapse v1.100+ or custom module)
```

**Custom Module for Media Rate Limiting:**

```python
# media_rate_limiter.py

import time
from collections import defaultdict
from synapse.module_api import ModuleApi
from synapse.module_api.errors import Codes

class MediaRateLimiter:
    def __init__(self, config: dict, api: ModuleApi):
        self.api = api
        self.uploads_per_user = defaultdict(list)
        self.uploads_per_second = config.get("uploads_per_second", 0.5)  # 1 per 2 seconds
        self.burst_count = config.get("burst_count", 5)

    async def check_media_file_for_spam(self, file_wrapper, file_info):
        user_id = file_info.get("user_id")
        now = time.time()

        # Clean old uploads (older than burst window)
        self.uploads_per_user[user_id] = [
            ts for ts in self.uploads_per_user[user_id]
            if now - ts < self.burst_count / self.uploads_per_second
        ]

        # Check burst limit
        if len(self.uploads_per_user[user_id]) >= self.burst_count:
            return Codes.LIMIT_EXCEEDED

        # Record this upload
        self.uploads_per_user[user_id].append(now)

        return Codes.NOT_SPAM

# ... module registration
```

**Configuration:**

```yaml
modules:
  - module: media_rate_limiter.MediaRateLimiter
    config:
      uploads_per_second: 0.5  # 1 upload per 2 seconds
      burst_count: 5  # Can burst 5 files quickly
```

**User Impact:**
- ⚠️ "Too many uploads - please wait before uploading again"
- ✅ Prevents abuse and spam

### 4.4 Content Reporting System (RECOMMENDED)

**Concept:** Allow users to report suspicious files

**Implementation: Element Web Configuration**

```json
// In Element Web config.json
{
  "enable_message_actions": true,
  "enable_report_event": true
}
```

**Backend: Admin Review Queue**

Create admin tool to review reported content:
- List reported files
- Preview file (safely sandboxed)
- Quarantine if malicious
- Notify reporter

### 4.5 User Education (MANDATORY)

**Training Topics:**
1. **Don't Execute Unknown Files**
   - "Don't run .exe files from chat"
   - "Verify sender before opening attachments"

2. **Use Endpoint Antivirus**
   - "Ensure your device has antivirus"
   - "Keep Windows Defender / ClamAV / etc. updated"

3. **Report Suspicious Content**
   - "See a suspicious file? Report it"
   - "Admins will investigate"

4. **Phishing Awareness**
   - "Don't click suspicious links"
   - "Verify URLs before visiting"

**Delivery Methods:**
- Onboarding training
- Monthly security reminders
- In-app notifications
- Poster / email campaigns

### 4.6 Endpoint Protection (RECOMMENDED)

**Strategy:** Protect user devices instead of server

**Tools:**
- **Windows:** Windows Defender (built-in), Symantec, CrowdStrike
- **macOS:** XProtect (built-in), Malwarebytes
- **Linux:** ClamAV, ESET
- **Mobile:** Android Play Protect, iOS built-in protections

**MDM (Mobile Device Management):**
- Enforce antivirus on company devices
- Block downloads from non-approved sources
- Remote wipe if device infected

### 4.7 Network Monitoring (ENTERPRISE)

**Tools:**
- **IDS/IPS:** Snort, Suricata, Zeek
- **SIEM:** Splunk, ELK Stack, Graylog
- **DLP:** McAfee, Symantec, Forcepoint

**Monitoring Indicators:**
- Suspicious outbound connections (C&C servers)
- Large data exfiltration
- Unusual file access patterns
- Known malware signatures in network traffic

---

## 5. Implementation: Deploying Without AV

### 5.1 Configuration Changes

**Step 1: Edit deployment.env**

```bash
cd deployment/
cp config/deployment.env.example config/deployment.env
vim config/deployment.env
```

**Add/modify:**

```bash
# ============================================================================
# ANTIVIRUS CONFIGURATION
# ============================================================================
# Set to "false" to deploy without antivirus scanning
# WARNING: Only disable if you understand the risks (see ANTIVIRUS-DISABLE-GUIDE.md)
ENABLE_ANTIVIRUS="false"

# If disabling AV, you MUST implement alternative security measures
# See ANTIVIRUS-DISABLE-GUIDE.md section 4

# Alternative Security Settings (if ENABLE_ANTIVIRUS=false)
ENABLE_FILE_TYPE_WHITELIST="true"      # Strongly recommended
MAX_UPLOAD_SIZE="100M"                  # Limit file size
ENABLE_UPLOAD_RATE_LIMITING="true"     # Prevent abuse
ENABLE_CONTENT_REPORTING="true"        # User reporting
```

**Step 2: Deploy File Type Whitelist Module**

```bash
# Copy module to project
cp /path/to/file_type_whitelist_checker.py deployment/config/

# Build Docker image with module (see Container Images guide)
# OR mount as ConfigMap in Kubernetes
```

**Step 3: Update Synapse Configuration**

Edit `deployment/manifests/05-synapse-main.yaml`:

```yaml
# Add ConfigMap for custom modules
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: synapse-custom-modules
  namespace: matrix
data:
  file_type_whitelist_checker.py: |
    # ... paste module code here ...
---
# In Synapse deployment, mount the module
spec:
  template:
    spec:
      containers:
      - name: synapse
        volumeMounts:
        - name: custom-modules
          mountPath: /modules
      volumes:
      - name: custom-modules
        configMap:
          name: synapse-custom-modules
```

**Update homeserver.yaml ConfigMap:**

```yaml
data:
  homeserver.yaml: |
    # ... existing config ...

    # Load custom spam-checker module
    modules:
      - module: modules.file_type_whitelist_checker.FileTypeWhitelistChecker
        config: {}

    # File size limit
    max_upload_size: "100M"

    # Rate limiting (media uploads)
    # Note: Synapse doesn't have native media rate limiting
    # You'd need to implement via custom module or nginx
```

**Step 4: Modify Deployment Script**

Edit `deployment/scripts/deploy-all.sh`:

```bash
# Add conditional AV deployment

phase_09_antivirus() {
    if [ "$ENABLE_ANTIVIRUS" = "true" ]; then
        print_header "Phase 9: Deploying Antivirus (ClamAV)"
        # ... existing ClamAV deployment ...
    else
        print_warning "Phase 9: Skipping Antivirus Deployment (disabled in config)"
        print_warning "⚠️  ENSURE alternative security measures are in place!"
        print_warning "⚠️  See deployment/docs/ANTIVIRUS-DISABLE-GUIDE.md"
    fi
}
```

### 5.2 Deployment Steps

**Step 1: Review Risks**
```bash
# Read the risk section of this document
less deployment/docs/ANTIVIRUS-DISABLE-GUIDE.md
```

**Step 2: Implement Alternatives**
```bash
# Ensure file type whitelist module is ready
# Configure rate limiting
# Set up content reporting
# Plan user training
```

**Step 3: Deploy**
```bash
cd deployment/
./scripts/deploy-all.sh
```

**Output will show:**
```
======================================================================
  Phase 9: Skipping Antivirus Deployment (disabled in config)
======================================================================

⚠️  ENSURE alternative security measures are in place!
⚠️  See deployment/docs/ANTIVIRUS-DISABLE-GUIDE.md

✓ File type whitelist enabled
✓ Upload size limit: 100MB
✓ Rate limiting configured
```

### 5.3 Verification

**Test File Type Restrictions:**

```bash
# Try to upload an executable (should fail)
# 1. Log into Element Web
# 2. Upload test.exe
# Expected: "Upload failed - file type not allowed"

# Try to upload an image (should succeed)
# 1. Upload test.jpg
# Expected: Success
```

**Test Upload Size Limit:**

```bash
# Create large file
dd if=/dev/zero of=large.bin bs=1M count=150

# Try to upload (should fail if >100MB)
# Expected: "File too large"
```

**Test Rate Limiting:**

```bash
# Rapidly upload 10 files
# Expected: First 5 succeed, then "Too many uploads"
```

---

## 6. Monitoring and Detection

Without automated scanning, you must rely on other detection methods:

### 6.1 User Reports

**Process:**
1. User reports suspicious file via Element Web
2. Admin receives notification
3. Admin reviews file (in isolated environment)
4. Admin quarantines if malicious
5. Admin notifies affected users

**SLA:** Respond to reports within 24 hours (business days)

### 6.2 Storage Growth Monitoring

**Indicators of malware:**
- Sudden spike in storage usage
- Specific user uploading huge amounts of data
- Many small files uploaded rapidly (worm behavior)

**Monitoring:**

```bash
# Grafana dashboard query (Prometheus)
# Alert if storage growth >100GB/day

rate(minio_bucket_usage_total_bytes{bucket="synapse-media"}[1d]) > 100e9
```

**Response:**
- Investigate top uploaders
- Review recent files manually
- Quarantine suspicious content

### 6.3 Behavioral Anomalies

**Red Flags:**
- User account suddenly uploading many files (compromised account)
- Files with suspicious names (e.g., "invoice.pdf.exe")
- Repeated uploads of same file hash (bot behavior)
- Uploads during off-hours (automated malware)

**Detection:**

```python
# Simple anomaly detection (pseudocode)

# Calculate baseline: average uploads per user per day
baseline = avg(uploads_per_user_per_day, last_30_days)

# Alert if user exceeds 3× baseline
if user_uploads_today > 3 * baseline:
    alert_admin(f"User {user_id} uploading abnormally high volume")
```

### 6.4 Endpoint Detection

**Strategy:** Detect infections on user devices, trace back to source

**Tools:**
- EDR (Endpoint Detection and Response): CrowdStrike, Carbon Black, SentinelOne
- MDM (Mobile Device Management): Intune, Jamf, VMware Workspace ONE

**Process:**
1. Endpoint AV detects malware
2. Admin investigates: Where did it come from?
3. Check user's Matrix download history
4. If from Matrix: quarantine file on server
5. Notify other users who downloaded the same file

### 6.5 Periodic Manual Audits

**Schedule:** Monthly or quarterly

**Process:**
1. Random sample 100 recent uploads
2. Download to isolated environment (VM with no network)
3. Scan with multiple AV engines (VirusTotal, hybrid-analysis)
4. Quarantine any detected malware
5. Track statistics: infection rate, types of malware

**Estimated Effort:** 2-4 hours per audit

---

## 7. Incident Response Without AV

### 7.1 Malware Detected Scenario

**Step 1: Contain**
```bash
# Quarantine the file via Synapse Admin API
MEDIA_ID="XYZ123"
SERVER_NAME="chat.example.com"

curl -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://chat.example.com/_synapse/admin/v1/media/quarantine/$SERVER_NAME/$MEDIA_ID" \
  -d '{"reason": "Malware detected via endpoint AV"}'
```

**Step 2: Identify Affected Users**
```bash
# Query who downloaded the file (requires custom logging)
# Check Synapse logs for media downloads

grep "$MEDIA_ID" /var/log/synapse/*.log | grep "GET.*media/download"
```

**Step 3: Notify**
```bash
# Send admin notice to all affected rooms
# Via Synapse Admin API or bot

# Message:
"⚠️ SECURITY ALERT: A file uploaded to this room was detected as malware.
The file has been removed. If you downloaded it, DO NOT OPEN IT.
Please scan your device with antivirus immediately.
Contact IT support if you opened the file."
```

**Step 4: Investigate**
- Who uploaded it?
- Was account compromised?
- Was it intentional or accidental?
- Review uploader's other files

**Step 5: Remediate**
- Suspend user account if compromised or malicious
- Force password reset
- Review access logs for data exfiltration
- Consider reimaging affected devices

### 7.2 False Alarm Handling

**Scenario:** User reports file as malware, but it's actually safe

**Step 1: Verify**
```bash
# Download file to isolated environment
# Scan with multiple AV engines

# VirusTotal (requires API key)
curl -X POST \
  -F "file=@suspected-file.pdf" \
  https://www.virustotal.com/api/v3/files \
  -H "x-apikey: YOUR_API_KEY"
```

**Step 2: If False Positive**
- Un-quarantine file
- Notify reporter: "Reviewed, file is safe"
- Document for future reference (hash of safe files)

**Step 3: If Actual Malware**
- Follow incident response above

---

## 8. Re-enabling Antivirus Later

### 8.1 When to Re-enable

**Triggers:**
- Malware incident occurred
- User base grew significantly
- Compliance requirements changed
- Budget became available
- Risk tolerance decreased

### 8.2 Migration Plan

**Step 1: Deploy Antivirus Components**
```bash
# Edit deployment.env
ENABLE_ANTIVIRUS="true"

# Deploy ClamAV
kubectl apply -f deployment/manifests/clamav.yaml

# Deploy scan workers
kubectl apply -f deployment/manifests/av-scan-worker.yaml
```

**Step 2: Historical File Scanning** (Optional)

```python
# Scan all existing files in media repository

import os
import clamd

clamd_client = clamd.ClamdNetworkSocket(host="clamav", port=3310)
media_dir = "/data/media"

for root, dirs, files in os.walk(media_dir):
    for file in files:
        file_path = os.path.join(root, file)
        try:
            with open(file_path, "rb") as f:
                result = clamd_client.instream(f)
                if result["stream"][0] != "OK":
                    print(f"Infected: {file_path} - {result['stream'][1]}")
                    # Quarantine via API
        except Exception as e:
            print(f"Error scanning {file_path}: {e}")
```

**Estimated Time:** 10-50 hours (depending on media volume)

**Step 3: Update Configuration**

```yaml
# Re-enable spam-checker module in homeserver.yaml
modules:
  - module: async_av_checker.AsyncAVChecker
    config:
      redis_host: "redis-synapse-master"
      # ... config ...
```

**Step 4: Monitor**
- Watch scan queue depth
- Verify infected files are quarantined
- Check false positive rate

### 8.3 Gradual Rollout

**Phase 1: Scan New Uploads Only**
- Deploy AV, start scanning new uploads
- Don't scan historical files yet

**Phase 2: Background Historical Scan**
- Scan existing files slowly in background
- Quarantine infected files found

**Phase 3: Full Protection**
- All files scanned
- Monitoring in place
- Incident response procedures updated

---

## 9. Documentation and Compliance

### 9.1 Terms of Service Update

**Add clause:**

```
File Uploads and Security:

This service does not perform automatic antivirus scanning of uploaded files.
Users are responsible for ensuring files they upload are safe and do not contain
malware or viruses.

By uploading files, you represent and warrant that:
- Files are free from viruses, trojans, worms, or other malicious code
- Files do not infringe on third-party intellectual property
- Files do not contain illegal content

We reserve the right to remove any content at our discretion. Users who upload
malicious content may have their accounts suspended.

UPLOADED FILES ARE NOT SCANNED. DOWNLOAD AND OPEN FILES AT YOUR OWN RISK.
USE ANTIVIRUS SOFTWARE ON YOUR DEVICE.
```

### 9.2 Privacy Policy Update

**Add section:**

```
File Storage and Security:

Uploaded files are stored on our servers without automatic malware scanning.
We may review files in response to user reports or security incidents.

Users are responsible for scanning downloaded files with their own antivirus
software before opening them.
```

### 9.3 Compliance Considerations

**Document decisions for auditors:**

1. **Risk Assessment:** Formal document explaining why AV was not implemented
2. **Compensating Controls:** List all alternative security measures
3. **User Training Records:** Evidence of security awareness training
4. **Incident Response Plan:** Procedures for handling malware reports
5. **Periodic Reviews:** Schedule for re-evaluating the decision

---

## 10. Summary and Checklist

### 10.1 Pre-Deployment Checklist

Before deploying without antivirus, confirm:

- [ ] **Risk Assessment Complete:** Documented decision rationale
- [ ] **Executive Approval:** Management signed off on risk
- [ ] **Alternative Security Implemented:**
  - [ ] File type whitelist configured
  - [ ] File size limits set
  - [ ] Upload rate limiting enabled
  - [ ] Content reporting system ready
- [ ] **User Education Planned:**
  - [ ] Training materials created
  - [ ] Delivery method identified
  - [ ] Schedule set
- [ ] **Endpoint Protection Verified:**
  - [ ] All devices have antivirus
  - [ ] AV signatures up to date
  - [ ] MDM enforcing AV policies (if applicable)
- [ ] **Monitoring Configured:**
  - [ ] Storage growth alerts
  - [ ] Anomaly detection
  - [ ] User report queue
- [ ] **Incident Response Ready:**
  - [ ] Procedures documented
  - [ ] Team trained
  - [ ] Tools prepared (isolated VM for file analysis)
- [ ] **Legal Protections:**
  - [ ] Terms of Service updated
  - [ ] Privacy Policy updated
  - [ ] User agreements signed
- [ ] **Documentation:**
  - [ ] Decision recorded in change log
  - [ ] Compliance records created
  - [ ] Audit trail established

### 10.2 Post-Deployment Validation

After deployment, verify:

- [ ] File type restrictions working (test executable upload - should fail)
- [ ] File size limits enforced (test oversized upload - should fail)
- [ ] Rate limiting active (test rapid uploads - should throttle)
- [ ] Content reporting functional (test report button - should work)
- [ ] Monitoring alerts configured (test alert - should fire)
- [ ] User training delivered (attendance records)
- [ ] Incident response tested (tabletop exercise)

### 10.3 Ongoing Maintenance

Monthly:
- [ ] Review upload statistics
- [ ] Check for anomalies
- [ ] Review user reports
- [ ] Refresh user training

Quarterly:
- [ ] Perform manual file audit
- [ ] Re-assess risk
- [ ] Review incident response procedures
- [ ] Update security policies

Annually:
- [ ] Formal risk re-assessment
- [ ] Consider re-enabling antivirus
- [ ] Compliance audit
- [ ] Executive review

---

## 11. Conclusion

**Disabling antivirus is a calculated risk.** It can be acceptable for:
- Small, trusted deployments
- Budget-constrained organizations
- Non-critical use cases

**But you MUST:**
1. Understand and accept the risks
2. Implement compensating controls
3. Educate users
4. Monitor actively
5. Be prepared to respond to incidents

**Remember:**
- One malware incident can cost far more than antivirus infrastructure
- "No AV" is not the same as "no security" - implement alternatives
- Be honest with users about the risks
- Document your decision for compliance

**Final Recommendation:**
If budget allows (~$200/month), **implement asynchronous antivirus scanning**.
The risk reduction is worth the cost for most production deployments.

If you truly cannot afford AV, follow this guide carefully and be vigilant.

---

**Document Version:** 1.0
**Last Updated:** November 10, 2025
**Maintained By:** Matrix/Synapse Production Deployment Team

**Questions?** Review `ANTIVIRUS-IMPLEMENTATION-CRITICAL-ANALYSIS.md` for the full async AV solution.
