# CLAUDE.md

**Repository guidelines for Claude Code**

This document tells Claude Code how to behave when editing this repository.

Whenever you generate, modify, or delete files here, you **must** follow these rules exactly, unless the user explicitly overrides them in a specific request.

---

## 1. High-level goals

- The goal of this repository is to provide a **Kubernetes-based deployment** of a Matrix stack (Synapse + Element + related services) for multiple organizations, with:
  - A **production (“main”) environment**: robust, fault-tolerant, scalable, and highly available.
  - A separate **lawful intercept (“LI”) environment**: used only by a small number of admin users to inspect user data under lawful conditions.

- Your main job is to:
  - Design and update the **architecture**, **Kubernetes manifests**, **configuration files**, and **operational documentation**.
  - Make **deployment, configuration, and updates as clear and simple as possible**, while staying robust and production-grade.

- You are **not** responsible for:
  - Provisioning VMs or physical servers.
  - Building container images or managing container registries.
  - Any task that requires access to the public internet after deployment (e.g. HTTPS certificate renewal).

---

## 2. Writing & documentation rules

2.1 **No changelogs or “what I did” reports**

- Do **not** create files whose purpose is to:
  - Describe your reasoning, step-by-step actions, or history of changes.
  - Act as a running log of your work (e.g. `WORKLOG.md`, `CHANGELOG.md`, `UPDATE_HISTORY.md`).
- Only the **current, final, usable solution** matters:
  - Keep the repository in a state where a human can clone it and directly use the latest recommended setup.

2.2 **No document versions or dates**

- Do **not** put document metadata like:
  - “Version 1.0”, “v2.3”, “Last updated: …”, “Updated on 2025-…”.
- The **content itself** must be self-sufficient; readers should not care when the document was last updated.
- Exception: **software configuration** may legitimately contain version tags (e.g. Docker image tags, Synapse version) when required for correctness.

2.3 **Instructions must be complete and actionable**

When you provide a command, file, or step:

- Explain **what it does** and **why it’s needed**.
- State **exactly where** to run it:
  - Which server (main vs LI vs monitoring vs backup).
  - Which context (Kubernetes cluster / namespace / node / shell).
- State **what must be edited beforehand**:
  - For any placeholder or variable, clearly describe what values are expected and how to choose them.
- For every action you prescribe, the user should be able to execute it correctly **without guessing**.

2.4 **Avoid unnecessary files and duplication**

- Before adding a new file:
  - Check whether an existing file is the right place for this content.
  - Prefer to **extend existing docs** and **reference sections** instead of duplicating text.
- Do **not** spread closely related material across many tiny documents.
  - Group related topics together in a small, coherent set of files.

2.5 **Explain configurable variables where the user edits them**

- For config files where the user is expected to set or tune variables:
  - Provide **short but clear comments** (or adjacent documentation) for each variable that a user might change.
  - Each such variable must have:
    - What it controls.
    - How it affects behaviour/performance/security.
    - How to choose a correct or typical value for different organization sizes.

2.6 **No unused files or directories**

- If a file or directory is not used anywhere, and does not contain unique, non-duplicated information, treat it as **dead weight**.
- Prefer **removing** unused artifacts rather than leaving them in the tree.
- Only keep files that:
  - Are required for deployment, operation, or understanding the system.
  - Or contain unique, relevant documentation.

2.7 **Respect the reading & execution flow**

- The **entry point for humans** is the root `README` of this solution.
- That `README` must:
  - Describe **which documents** to read in which order.
  - Describe **which steps** to perform in which order.
  - Ensure **dependencies between steps** are respected (prerequisite configs come before dependent ones).
- Whenever you change the structure, file names, or major workflows:
  - **Update the root `README`** so the overall flow remains correct and logical.

2.8 **No time or cost estimates**

- Do not include:
  - Time estimates (“This will take ~30 minutes”).
  - Cost estimates (“This setup costs about … per month”).
- Keep the content purely **technical and operational**.

---

## 3. Architecture overview

3.1 **Main environment (production)**

- Matrix homeserver: **Synapse**.
- Web client: **Element Web**.
- Supporting services: database(s), media storage, ClamAV scanning, monitoring, logging, backup, etc.
- Requirements:
  - Robust, fault-tolerant.
  - High performance and **scalable**.
  - High availability (**HA**) for all critical components:
    - Any service whose absence would break core messaging must support HA, with **automatic failover**.

3.2 **Lawful intercept (LI) environment**

- Separate set of services:
  - `synapse-li`
  - `synapse-admin-li`
  - `element-web-li`
  - `key_vault`
- Purpose:
  - Allow a privileged LI admin to:
    - Change a user’s password via `synapse-admin-li`.
    - Fetch that user’s recovery key from `key_vault`.
    - Decrypt the recovery key with a private key.
    - Log in to `element-web-li` as that user and supply the recovery key.
    - View all rooms and contents for that user (and any others the admin is authorized to inspect).
  - In LI, the admin must also be able to:
    - View **deleted messages**.
    - See them **clearly distinguished** (e.g. different style/marker) to recognize they were deleted.

- Many details about LI behaviour and other requirements are defined in **existing documents in the project root**.
  - **LI_IMPLEMENTATION.md** - Comprehensive documentation of all LI code changes:
    - Component implementations (key_vault, element-web, synapse, synapse-admin-li, sync system)
    - REST API endpoints (sync trigger, status)
    - Frontend components (sync button, decryption tool)
    - User flows and error handling
  - Before changing LI-related config or architecture, **review those docs** to understand:
    - What code changes already exist.
    - Which services they affect.
    - What extra configuration / deployment behaviour is required.

3.3 **Relationship between main and LI**

- `homeserver` name in LI **must be identical** to the main environment's homeserver name.
- `element-web-li` and `synapse-admin-li` must **connect to `synapse-li`**, not to the main Synapse.
- All servers (main and LI) are in the **same network** and can communicate without restrictions.
- From the main environment:
  - Main Synapse may access `key_vault` for storing recovery keys.
- Data synchronization from main → LI:
  - Uses **pg_dump/pg_restore** for full database synchronization.
  - Sync **interval must be configurable** (via Kubernetes CronJob).
  - LI admin must be able to **trigger a sync manually** from synapse-admin-li.
    - Implementation: See **LI_IMPLEMENTATION.md Component 10** (Sync Button)
    - REST API: `POST /_synapse/admin/v1/li/sync/trigger` (synapse-li)
    - UI: Sync button in synapse-admin-li AppBar
  - At any time, there must be **at most one sync process** in progress (enforced via file lock).
  - Each sync **completely overwrites** the LI database with a fresh copy from main.
  - Any changes made in LI (such as password resets) are lost after the next sync.
  - Further behavioral details are in the existing root-level docs; consult them as needed.

3.4 **HA scope**

- **HA and automatic failover** are required only for the **main** environment.
- The **LI environment does NOT require HA**:
  - All LI services (`synapse-li`, `synapse-admin-li`, `element-web-li`, `key_vault`) are used by one or a few admin users only.
  - LI can run on a **single server** (see also section 7).
  - `key_vault` may run on the same server as LI or on a dedicated one; choose what is architecturally cleaner and document that choice.

---

## 4. Kubernetes & deployment principles

4.1 **Use Kubernetes best practices**

- Design manifests and architecture according to **Kubernetes best practices**, including (non-exhaustive):
  - Separation of concerns (deployments, services, configmaps, secrets, jobs, cronjobs, etc.).
  - Resource requests/limits for all pods.
  - Liveness and readiness probes.
  - Proper use of storage classes and persistent volumes.
  - Pod anti-affinity / topology settings where needed for HA.
  - Configurable horizontal or vertical scaling where appropriate.
- Whenever Kubernetes provides built-in mechanisms that match a requirement (e.g. CronJobs for backups), **use them** instead of inventing custom ad-hoc solutions.

4.2 **Stable architecture across scales**

- The **overall architecture and design** must be **the same** for all deployment scales.
- To handle different sizes of customer organizations:
  - Only change **parameters** such as:
    - Number of servers / nodes.
    - Number of pods / replicas.
    - Resource limits/requests.
    - Number of worker threads or workers per service.
  - Do **not** create separate architectures for “small”, “medium”, “large”.
- Document clearly **which knobs** to change for scaling.

4.3 **Intranet/Air-gapped operation requirement**

- After initial deployment, the messenger **MUST work completely without internet access**.
- The system will run in the organization's **intranet** with no external connectivity.
- Therefore:
  - Do **not** rely on any external SaaS or internet services for core functionality.
  - Disable Matrix **bridges** and **integrations** by default on the backend.
  - All features that depend on internet access must be **off by default** in configuration.
  - All inter-service communication happens within the internal network.
- The deployment must ensure:
  - All required container images are available in the organization's internal registry.
  - All services can discover and communicate with each other via internal DNS.
  - No external API calls, webhooks, or internet dependencies in normal operation.
  - The messenger functions fully for messaging, calls, file sharing, and LI operations.

4.4 **Internet-dependent maintenance is out of scope**

- Both main and LI environments **must** be exposed over **HTTPS**.
- The deployment solution covers: **Configure → Deploy → Update** (version upgrades).
- After deployment, **ongoing maintenance tasks that require internet access are the organization's responsibility**, including:
  - TLS certificate renewal (ACME, Let's Encrypt).
  - Antivirus definition updates (ClamAV freshclam).
  - Operating system or package updates.
  - Security patches that require downloading from the internet.
- You **must not**:
  - Describe or document how to handle these internet-dependent maintenance tasks.
  - Assume internet connectivity is available after initial deployment.
- The organization's infrastructure team handles all ongoing internet-dependent maintenance.
- **Clarification**: Operational procedures (like air-gapped/secure key decryption for LI) are VALID and should be documented. The restriction is only on internet-dependent maintenance procedures.

4.5 **TLS certificate setup**

- All services **must** be exposed over **HTTPS** with valid TLS certificates.
- The deployment supports multiple TLS provisioning methods:
  - **Let's Encrypt** (via cert-manager): For initial deployment when internet access is available.
  - **Organization's internal CA**: For fully intranet deployments where the organization manages their own PKI.
  - **Manual certificates**: Organization provides pre-generated certificates.
- What to include:
  - cert-manager installation and ClusterIssuer configuration (for Let's Encrypt or CA issuers).
  - Ingress annotations for certificate generation.
  - Instructions for using organization-provided certificates.
  - Verification that TLS is working correctly.
- What NOT to include:
  - Certificate renewal procedures (organization's responsibility).
  - Troubleshooting for post-deployment certificate issues.
- **Important for intranet deployments**: If Let's Encrypt cannot be used (no internet), the organization must provide certificates from their internal CA or generate them manually before deployment.

4.6 **Images and registries are out of scope**

- Do **not** describe:
  - How to build Docker images.
  - How to push/pull from registries.
- Configuration should:
  - Assume the existence of image references (e.g. `image: registry.example.com/synapse:tag`) that the user sets.
- Focus on:
  - **How to configure, deploy, scale, and update** the system using those images.

---

## 5. Servers, networks, and connectivity

5.1 **Server assumptions**

- The organization provides:
  - A number of **Debian servers** with internal IPs.
  - Servers can reach each other over the organization’s internal network.
  - We assume they are likely VMs, but provisioning is outside our scope.
- We **do not**:
  - Explain how to create VMs.
  - Describe hypervisors or cloud providers.
- We can assume:
  - SSH access to each server.
  - No special software is pre-installed; any required package or tool must be installed as part of this solution.

5.2 **Networking & routing correctness**

- There are many interacting services and routes between them.
- You must ensure:
  - All required **network paths** (service → service, service → database, main → key_vault, etc.) are defined and documented.
  - No missing or incorrect routes that would prevent normal operation.
- Take into account:
  - HA topologies (multiple replicas, failover paths).
- **No security-only network configurations**:
  - Do **not** include NetworkPolicies, firewall rules, or ingress restrictions that exist only for security purposes.
  - The deployment assumes all servers are in a trusted internal network.
  - Focus on **functional connectivity**, not on restricting access.

5.3 **Management node**

- The management node is a **dedicated computer** in the organization's network.
- It is **not** one of the Kubernetes cluster nodes (not a control plane or worker node).
- All kubectl, helm, and deployment commands are executed from this management node.
- Do **not** document alternative management node configurations (e.g., using a control plane node as management node).

---

## 6. Backups, monitoring, and logging

6.1 **Backups**

- Backups are **critical**.
- Requirements:
  - Backup jobs must run **automatically** at a **configurable interval**.
  - Backup data must be stored on a **separate server** from the main environment.
- Design:
  - Use Kubernetes CronJobs or equivalent mechanisms where appropriate.
  - Clearly document:
    - What is backed up (databases, media, configs, etc.).
    - How to configure schedules and destinations.

6.2 **Monitoring & logging**

- Monitoring must run on a **dedicated server** (separate from main and LI workloads).
- All logs from all services in the **main environment** must be:
  - Collected and forwarded to this monitoring/logging server.
- LI environment:
  - Does **not** require monitoring or HA.
  - It is acceptable for LI logging to be minimal, as long as legal requirements are not contradicted by the design (details are outside this document’s scope).

---

## 7. LI environment deployment specifics

7.1 **Single-server deployment**

- All LI services (`synapse-li`, `synapse-admin-li`, `element-web-li`, `key_vault`) must run on **one server**.
- The LI environment:
  - Is used only by one or a few administrators.
  - Does **not** need HA or scaling features.
- `key_vault` runs on the same server as other LI services for simplicity.

7.2 **Independence from main instance**

- The LI instance must be **operationally independent** for core functionality:
  - LI has its **own PostgreSQL database** (synchronized from main via pg_dump/pg_restore).
  - LI database is **writable** (LI admin can reset user passwords).
  - LI has its **own Redis cache**.
  - LI has its **own reverse proxy** (nginx-li).
- LI shares **main MinIO** for media storage (see section 7.5):
  - This is acceptable because media is read-only for LI.
  - If main MinIO is down, LI can still access cached/local media.
  - New media will not be accessible until main MinIO recovers.
- If the main instance fails:
  - LI admins can still browse LI URLs, log in, and perform lawful intercept.
  - Message history and user data remain accessible (in LI database).
  - Media may be temporarily unavailable if main MinIO is also down.
  - New data will not sync until main recovers.
- The LI instance must have its **own reverse proxy** (such as NGINX) that:
  - Operates independently of the main instance's ingress/proxy.
  - Handles TLS termination for all LI services.
  - Routes requests to `synapse-li`, `element-web-li`, `synapse-admin-li`, and `key_vault`.

7.3 **LI domains and DNS configuration**

- LI services require their own domains or subdomains:
  - `element-web-li`: Different domain (e.g., `chat-li.example.com`)
  - `synapse-admin-li`: Different domain (e.g., `admin-li.example.com`)
  - `key_vault`: Different domain (e.g., `keyvault.example.com`)
  - `synapse-li` homeserver: **Same homeserver URL** as main instance (e.g., `matrix.example.com`)
- The homeserver URL must be **identical** to the main instance because:
  - User IDs reference this server name (`@user:matrix.example.com`).
  - Event signatures and tokens are bound to this server name.
  - LI uses replicated data from main; different server names would break authentication.
- **DNS configuration for LI admins**:
  - LI admins must configure DNS on their computer or the LI network to resolve the homeserver URL (`matrix.example.com`) to the **LI server IP**, not the main instance IP.
  - This can be done via:
    - Local `/etc/hosts` file on the admin's workstation.
    - A dedicated DNS server in the LI network.
    - Organization-managed DNS split-horizon configuration.
  - Without this DNS configuration, Element Web LI and Synapse Admin LI would try to connect to the main Synapse instead of Synapse LI.

7.4 **LI access control is organization's responsibility**

- All servers (main and LI) are in the **same network**.
- The organization must ensure that only authorized LI administrators can access LI services.
- This access control is **outside the scope** of this deployment solution.
- The deployment does **not** implement:
  - NetworkPolicies to restrict LI access.
  - Firewall rules specific to LI isolation.
  - Any network-level access control.
- Cross-service connections:
  - **Data sync**: pg_dump from main PostgreSQL, pg_restore to LI PostgreSQL.
  - **Media access**: LI Synapse reads directly from main MinIO (shared S3 bucket).
  - **key_vault writes**: Synapse main stores recovery keys in key_vault.

7.5 **Shared MinIO for media storage**

- LI instance uses the **main MinIO** directly for media access (no separate LI MinIO).
- Rationale:
  - Simplifies architecture (no media sync needed).
  - Reduces storage requirements on LI server.
  - Provides real-time media access without sync lag.
- Requirements:
  - LI Synapse connects to main MinIO using S3 credentials.
  - LI Synapse uses the **same bucket** (`synapse-media`) as main Synapse.
- **CRITICAL WARNING for LI administrators**:
  - LI admin access to media is **read-only in practice**.
  - LI admins **must NOT delete or modify media files**.
  - Any file changes in MinIO affect the main instance.
  - Media quarantine or deletion must be done through main Synapse Admin, not LI.

---

## 8. File scanning with ClamAV

- All files uploaded by users in the **main** environment must be scanned before they can be widely accessed.
- Requirements:
  - Use **ClamAV** as the antivirus scanning service.
  - The ClamAV deployment must be **scalable**:
    - Able to scale up based on organization size and usage.
  - **Each file should be scanned only once** to avoid wasting resources:
    - The matrix-content-scanner uses **in-memory TTL caching** (cachetools.TTLCache).
    - Each scanner pod maintains its own cache; there is NO shared Redis cache.
    - Configure `result_cache.max_size` and `result_cache.ttl` for cache behaviour.
    - Note: Redis caching is NOT supported by matrix-content-scanner-python.
  - **Files in encrypted rooms (E2EE) must also be scanned**:
    - The scanner must be able to decrypt encrypted media for scanning.
    - Decryption happens in memory only; decrypted content must never be persisted to disk.
  - If a file is detected as malicious:
    - It must be **quarantined**.
    - Other room members must **not** be able to download it.
- Your design:
  - Must integrate ClamAV cleanly with Synapse's media handling.
  - Must provide configuration options for tuning ClamAV capacity and behaviour.

---

## 9. Configuration files & variables

9.1 **Centralized configuration directory**

- Prefer to keep all important configuration files for the messaging system and its components in a **central directory** tree.
  - Example: a top-level `config/` or similar.
- The goal:
  - The operator can inspect and adjust all relevant configurations in one place.

9.2 **Ordering and completeness of variables**

- For each configuration file:
  - Place the **most important and commonly adjusted variables at the top**.
  - Place the least important / rarely adjusted variables towards the bottom.
- Ensure:
  - All **configurable** variables for each service that matter to deployment behaviour are present.
  - There are no “hidden” required settings that exist only in code or are implied but never exposed in the config files.

9.3 **Default values**

- Provide **sensible default values** for all variables.
  - Defaults should be **safe and practical** for a typical small-to-medium deployment.
- The user should typically only need to change a **small subset** of variables for a new organization.

9.4 **Explanations of variables**

- For each configurable variable:
  - Provide enough explanation so the operator can:
    - Understand what it controls.
    - Understand the trade-offs.
    - Choose an appropriate value for their organization.
- For numeric variables:
  - When possible, provide simple **formulas or rules of thumb**.
    - Example: “Set this to 2 × number of CPU cores”.
- For qualitative or enumerated options:
  - Describe **when to choose each option**.

9.5 **Configure only what is necessary**

- **Do configure**:
  - Any variable that **must** be set for correct, secure, or performant operation.
- **Do not configure**:
  - Variables that can safely remain at their built-in defaults.
  - Options that provide no benefit and add complexity in this scenario.
- The configuration should be minimal but **sufficient**, not maximal.

---

## 10. Automation & scripts

10.1 **Deployment scripts are encouraged**

- Steps that can be reliably automated should be implemented as scripts.
- Scripts may:
  - Read organization-specific inputs (domains, IPs, sizing parameters, passwords, etc.) from one or more config files.
  - Apply those inputs to generate Kubernetes manifests, secrets, and other artifacts.

10.2 **Idempotence and safety**

- Scripts must be **safe to re-run**:
  - If a script fails halfway, the operator may fix the issue and run it again.
  - Re-running must **not break** the system or duplicate irreversible actions.
- For steps that must only run once:
  - Scripts must perform **state checks** to avoid repeating destructive or one-shot operations.
- For steps whose outcome does not depend on current state:
  - State checks may be omitted where appropriate.

10.3 **Clarity of automation**

- For each script:
  - Document:
    - What it does.
    - Inputs it expects.
    - Preconditions required.
    - Expected outputs / effects.
- Keep scripts **focused and understandable**, not overly magical or opaque.

---

## 11. Scaling, performance, and updates

11.1 **Updating the system**

- The solution must explain how to:
  - Upgrade component images to newer versions.
  - Increase resources (CPU/memory) for services.
  - Increase or decrease the number of pods/replicas for specific services.
- Provide a **clear guide** that covers:
  - Common update scenarios.
  - The recommended order of operations.
  - Any required checks before/after updates.

11.2 **Scaling and bottlenecks**

- The system must be designed to:
  - Handle large deployments (e.g. 20,000 concurrent active users with heavy usage).
- After any architectural or configuration change:
  - Re-evaluate whether new bottlenecks or single points of failure have been introduced.
  - Address obvious scalability limits where reasonable within the chosen technologies.

11.3 **Performance-related configuration**

- When exposing performance-sensitive settings:
  - Explain how they interact with:
    - User counts.
    - Message rates.
    - Hardware capacity.
    - Network characteristics.
- Avoid configurations that are safe only for trivial loads unless clearly marked and justified.

---

## 12. Federation & external integrations

- Matrix federation must be **disabled by default**.
- If an organization later wants to enable federation:
  - Provide clear documentation on:
    - Which config options must be changed.
    - How to adjust networking and TLS to support it.
- As stated earlier, **bridges and integrations** with external systems must be disabled by default and treated as **out of scope**.

---

## 13. Change management and global consistency

13.1 **Always investigate the underlying service**

- Before proposing or implementing **any technical change** to a service:
  - First, look for the **service’s repository or docs inside this project**.
  - Read enough to understand:
    - How the service behaves.
    - What configuration options exist.
    - How it interacts with other components.
  - If the repo or docs are not present here:
    - Use up-to-date and reputable external documentation (conceptually; in practice, you as Claude rely on your tools and training).
- Only propose changes after you have a **coherent understanding** of how that service is supposed to work.

13.2 **Always consider cross-system consequences**

- For every change you suggest or implement:
  - Consider the impact on:
    - Other services.
    - Networking.
    - Storage.
    - Security.
    - Performance and scalability.
- Do not introduce changes that:
  - Create new bottlenecks.
  - Break required interactions between components.
  - Contradict HA or isolation requirements.

13.3 **Re-review the whole solution after changes**

- After making any non-trivial change:
  - Re-check:
    - The overall architecture diagrams (if present).
    - The main and LI flows.
    - The root `README` and any top-level docs.
  - Ensure that:
    - All references remain correct.
    - The step-by-step instructions are still valid.
    - No obsolete or conflicting guidance remains.

---

## 14. Behaviour expectations for Claude Code

When working in this repository, you (Claude Code) must:

1. **Obey this CLAUDE.md first**, and the user’s explicit instructions second, unless the user clearly overrides a specific rule.
2. Prefer to:
   - Improve and refactor the **existing** structure.
   - Keep the number of files reasonably small and coherent.
3. For any new file or significant change:
   - Ensure it fits cleanly into:
     - The directory structure.
     - The documented workflows.
4. Never:
   - Add time or cost estimates.
   - Add document version/“last updated” tags.
   - Depend on external SaaS, internet availability, or third-party infrastructure beyond what the user explicitly provides.

By following these rules, you will produce a deployment solution that is stable, clear, maintainable, and suitable for large-scale, on-premise Matrix/Synapse/Element deployments with a dedicated lawful intercept environment.
