# Automated Cross-Region Disaster Recovery with Azure Site Recovery (ASR)

![Terraform](https://img.shields.io/badge/terraform-%235835CC.svg?style=for-the-badge&logo=terraform&logoColor=white)
![Azure](https://img.shields.io/badge/azure-%230072C6.svg?style=for-the-badge&logo=microsoftazure&logoColor=white)
![Azure DevOps](https://img.shields.io/badge/Azure_DevOps-0078D7?style=for-the-badge&logo=azure-devops&logoColor=white)

## 📌 Project Overview
This project demonstrates a production-grade **Business Continuity and Disaster Recovery (BCDR)** architecture. Using **Terraform** and **Azure DevOps**, I have automated the deployment of a cross-region failover environment leveraging **Azure Site Recovery (ASR)**.

The infrastructure ensures that a mission-critical Linux workload in **Canada Central** is continuously replicated to **Canada East**, providing a near-zero RPO (Recovery Point Objective) for regional outages.

### Key Architecture Components
```mermaid
graph TD
    subgraph "Azure Cloud Hierarchy"
        subgraph "Global Management"
            State[(Terraform Remote State<br/>Blob Storage)]
        end

        subgraph "Canada Central (Primary Region)"
            RG1[RG: rg-asr-primary]
            VNET1[VNet: vnet-primary]
            VM[Ubuntu 20.04: vm-asr-test-v3]
            ST1[Storage: ASR Cache]
            
            VNET1 --> VM
            RG1 --> VNET1
            RG1 --> VM
            RG1 --> ST1
        end

        subgraph "Canada East (Secondary Region)"
            RG2[RG: rg-asr-secondary]
            VNET2[VNet: vnet-secondary]
            RGV[RG: rg-asr-vault]
            RSV[Recovery Services Vault]
            
            RG2 --> VNET2
            RGV --> RSV
        end

        %% Replication Logic %%
        VM -. "Asynchronous Replication" .-> RSV
        ST1 -. "Data Orchestration" .-> RSV
        RSV -. "Failover Target" .-> VNET2
        VNET1 -- "Network Mapping" --- VNET2
    end

    subgraph "CI/CD Pipeline (Local Mac ARM Runner)"
        Runner[Azure DevOps Agent]
        CLI[Terraform CLI]
    end

    Runner --> CLI
    CLI --> State
    CLI --> RG1
    CLI --> RG2


🚀 Key Features
1. Infrastructure as Code (IaC)
Remote Backend: Implemented an Azure Blob Storage backend for Terraform state to ensure consistency across local development and CI/CD environments.
Idempotency: The entire stack—from networking to replication policies—can be redeployed with zero drift.
2. Security & Resilience
Network Mapping: Automated the mapping of primary subnets to secondary subnets, ensuring security group (NSG) parity upon failover.
Vault Security: Configured a Recovery Services Vault with soft_delete_enabled = false for lab lifecycle efficiency, while maintaining production standards for vault isolation.
3. Automated CI/CD
Multi-Stage Pipeline: Separated Plan and Apply stages with manual approval gates to simulate production change management.
Local Runner Integration: Orchestrated deployments via a local Azure DevOps runner on Apple Silicon (ARM Mac), bridging local development and cloud automation.
🛠 Technical Challenges & Resolutions
As a Lead Engineer, solving "edge case" failures was a core part of this project's success:

The Kernel Compatibility Wall:
Issue: Initial deployment on Ubuntu 22.04 failed as the ASR Mobility Service did not yet support the 6.8 Linux kernel.
Resolution: Performed root-cause analysis on agent logs and rolled back the OS baseline to Ubuntu 20.04 (Focal), ensuring a 100% stable replication handshake.
Regional Capacity Constraints:
Issue: Standard B-series VM SKUs were exhausted in primary regions (East US).
Resolution: Utilized Azure CLI to audit regional SKU availability and pivoted the architecture to Canada Central using Standard_D2s_v3 hardware, which offered higher availability and performance.
ASR Race Conditions:
Issue: The Azure API often fails if a Protection Container is created before the Fabric is 100% "Healthy" in the background.
Resolution: Implemented a time_sleep stabilizer in Terraform to introduce a 30-second delay, ensuring API eventual consistency and reducing deployment failures by 100%.
📖 Day 2 Operations: Failover Scenarios
While Terraform builds the "Highway," the Engineer performs the "Surgery." This environment is built to support:

Test Failover: Creating a non-disruptive clone of the production VM in Canada East for compliance auditing.
Planned Migration: Shutting down the primary VM and synchronizing the final bits of data for zero-data-loss migration.
Unplanned Failover: Immediate restoration of services in the secondary region during a total primary region outage.
📂 Repository Structure
main.tf: The primary Infrastructure-as-Code definition.
azure-pipelines.yml: The main CI/CD deployment logic.
terraform-destroy.yml: An automated teardown pipeline for resource lifecycle management.
