# AWS Multi-Tier VPC Networking Project

This repository contains an Infrastructure-as-Code (IaC) implementation of a secure, production-ready AWS network architecture. The project demonstrates core cloud networking principles including VPC design, subnet isolation, and secure internet routing.

## 🏗️ Architecture Overview
This architecture follows the **"Least Privilege" networking model**, ensuring that compute resources are isolated from direct public access.

* **VPC:** A private virtual network (10.0.0.0/16).
* **Public Subnet:** Houses the NAT Gateway, providing a secure path for private resources to reach the internet for updates.
* **Private Subnet:** Houses application/compute resources. These instances have no public IP addresses and cannot be reached directly from the internet.
* **Routing:** * Public traffic is routed via an **Internet Gateway**.
    * Private traffic is routed via a **NAT Gateway**.

## 🚀 Key Technologies
* **Terraform:** Used to provision all networking components in a modular, repeatable way.
* **AWS VPC:** Custom network segmentation.
* **NAT Gateway:** Managed service for private network internet access.
* **Routing Tables:** Precise control over network traffic flow.

## 🛠️ Getting Started
### Prerequisites
* [Terraform](https://www.terraform.io/downloads.html) installed locally.
* [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials.

### Deployment
1. Clone this repository:
   ```bash
   git clone [https://github.com/Adonitologist/aws-vpc-networking-project.git](https://github.com/Adonitologist/aws-vpc-networking-project.git)
   cd aws-vpc-networking-project
