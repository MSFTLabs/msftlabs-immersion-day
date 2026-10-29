Scenario:

- A county digital-services team needs a lightweight public status page. The page will run on an Azure VM, store its web content on a separate managed disk, allow web traffic through an NSG rule, and expose operational metrics through Azure Monitor.
- Lab Machines will be hosted in AVD preloaded with required tools/access.
- Precreate demo users.
- Must reset after labs completed
- Tenant should include TAP support

Additional Talking Points/Topics:

- TAGS - Constantly reenforce the importance of tagging!
- ALZ - talk about how this would look in typical Azure LazazafndingZone.
- Policy - Talk about Azure Policy

Lab Setup Reqs:

- Give each user dedicated ResourceGroup to spin this up in.
- A dedicated Tenant to spin this up in. We'll need Owner at Tenant root for our Terraform Deploy.
- No MCAPS policy disabling public endpoints on stuff!
- Each user will need to be Owner at their Resource Group (SAMI Permissions)
- Terraform to spin up environment (We use this to deploy the Lab - the Students will never touch Terraform!)
  - AVD for labhosts (size/region) - golden image with tools installed?a
    - Tools like Markdown Viewer/Reader, vscode, azcli (install via WinGet)
    - Load Scripts/Lab Directory directly from GitHub Repo (public)
  - Create Users - feed from simple CSV
  - Create Resource Groups for each user (unique-guid for Global Unique Requirement)

> Students will use AVD Webbased desktops where they will login to Azure Portal and open Guides (using markdown viewer) and follow the instructions.

> We can consider validating the users work by exporting ARM and using Pester to validate everything is there at the end of each LAB.

Topics:

- LAB01: Introduction to Azure Networking - Level 100

  - Time: ~1hr (not including lecture)
  - Description: Learn about Azure Networking by walking through deploying VNET, Azure Bastion, and NSGs || A level 200/300 version of this could include Secure vWAN Hubs + Azure Firewall and routing
  - Workshop Guides:
    - Create Virtual Networksasd
    - Create Three Subnets
      - BastionSubnet (Explain what Bastion Service is)
      - Subnet1
      - Subnet2
    - Create Two NSG (so we can demonstrate how to control traffic between subnets.)
      - subnet1-nsg | Lock them down
      - subnet2-nsg | Lock them down
    - Deploy Azure Bastion Service (so we can talk about how to protect\secure your access to VMs)
    - Create Keyvault for SSH Keys needed for Ubuntu VM (bastion can native reference KV.) using SAMI (Bastion and VM)
- LAB02: Introduction to Azure Storage Accounts - Level 100

  - Time: ~30m (not including lecture)
  - Description: Learn about deploy azure Storage Accounts. Cover topics like Sku, Resilency, LCM, Blob vs File, Managed Disks, Immutability/Versioning. || Level 200/300 version of this lab should cover Private Endpoints and securing Storage Accounts.
    - Must be globally unique!!
    - Upload CSE Scripts (container1)
    - Upload Images/Static content (container2)
    - Private using SAMI
    - Public Endpoint Enabled (talk about private endpoints)
- LAB03: Introduction to Azure Virtual Machines - Level 100

  - Time: ~1hr (not including lecture)
  - Description: Learn about deploying Azure Virtual Machines from the marketplace. Will cover sizing, skus, families, monitoring, availability zones, extensions (automation) and availability sets. || A level 200/300 version of Application Gateway vs ELB for this. || Need to find available SKU and Region -> Pre check region/sku availability prior to event.
  - Workshop Guides:
    - Create External Load-Balancer + PIP (explain how this impact outbound egress and why you should NEVER put a PIP on a VM.. ) on subnet1
    - Create Ubuntu VM1 on Subnet2 using DSE to install nginx (or any other webserver) and configure simple Status Page (HTML) -> This will give a chance to explain VM Extensions (when/why use them).
      - Configure CSE to point to bash script on Storage Account
      - Configure SAMI and grant required permissions
    - Validate Access to VM from Bastion Service (SSH)
    - Configure Load balancer to point to 80 on VM1
    - Validate Page from http://<PIP></pip>
    - Open NSG for INTERNET <-> TCP/HTTP 80 on Subnet2 - explain more about this..
- LAB04: Monitoring and Observability in the Cloud - Level 100

  - Time: ~2hr (not inlcuding lecture)
  - Description: This will include building dashboard using Grafana for Azure Monitor Dashboards and working with Azure SRE Agent
  - Workshop Guides:
    - Create Log Analytics Workspace.. Explain the purpose of this and how to control costs.
    - Configure Vnet/Subnet flow logs (portal)
    - Configure VM Telemetry and DCR (perf) to fwd to LAW
    - Demonstrate KQL on getting data out of logs/telemetry
    - Build Azure Dashboard and Azure Monitor Grafana Dashboard | talk about the differences..
    - Build out Alerts/Groups
    - Demonstrate Azure SRE Agent
