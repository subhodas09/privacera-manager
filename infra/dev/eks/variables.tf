variable "aws_region" {
  description = "AWS Region containing both the VPC state and the EKS cluster."
  type        = string
  default     = "ap-southeast-2"
}

variable "aws_profile" {
  description = "AWS shared-config profile used by the provider and VPC remote-state reader. Set to null for environment, role, or workload credentials."
  type        = string
  default     = null
  nullable    = true
}

variable "allowed_account_ids" {
  description = "Optional account allow-list that prevents applying to the wrong AWS account. Set this in terraform.tfvars."
  type        = list(string)
  default     = []
}

variable "project_name" {
  description = "Short project identifier used in resource names and tags. Must match the VPC stack."
  type        = string
  default     = "privacera"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-32 lowercase alphanumeric/hyphen characters and may not start or end with a hyphen."
  }
}

variable "environment" {
  description = "Deployment environment. This stack is intentionally restricted to development."
  type        = string
  default     = "dev"

  validation {
    condition     = var.environment == "dev"
    error_message = "This root module is for the dev environment only."
  }
}

variable "cluster_name" {
  description = "Required EKS cluster name for this Privacera environment."
  type        = string
  default     = "privacera-cluster"

  validation {
    condition     = var.cluster_name == "privacera-cluster"
    error_message = "The required EKS cluster name is privacera-cluster."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version supported by PRIVACERA_VERSION=9.0.29.1. Re-check Privacera's compatibility matrix whenever Privacera is upgraded."
  type        = string
  default     = "1.32"

  validation {
    condition     = var.kubernetes_version == "1.32"
    error_message = "Privacera 9.0.29.1 supports EKS only up to Kubernetes 1.32. Re-check the compatibility matrix before changing this guardrail."
  }
}

variable "vpc_state_bucket" {
  description = "S3 bucket holding the VPC Terraform state."
  type        = string
}

variable "vpc_state_key" {
  description = "S3 object key for the VPC Terraform state."
  type        = string
  default     = "privacera/dev/vpc/terraform.tfstate"
}

variable "vpc_state_region" {
  description = "Region of the Terraform-state S3 bucket."
  type        = string
  default     = "ap-southeast-2"
}

variable "vpc_state_kms_key_id" {
  description = "Optional KMS key ARN or ID used to encrypt the VPC state object."
  type        = string
  default     = null
  nullable    = true
}

variable "vpc_state_role_arn" {
  description = "Optional IAM role to assume when reading VPC remote state."
  type        = string
  default     = null
  nullable    = true
}

variable "cluster_admin_principal_arns" {
  description = "IAM role or user ARNs granted EKS cluster-admin through standard access entries. Prefer roles with temporary credentials for long-term use."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.cluster_admin_principal_arns : can(regex("^arn:[^:]+:iam::[0-9]{12}:(role|user)/.+$", arn))])
    error_message = "Every cluster administrator must be an IAM role or user ARN."
  }
}

variable "endpoint_public_access" {
  description = "Enable the public Kubernetes API endpoint. The secure default is private-only access."
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "Trusted CIDRs for the public API endpoint if enabled. 0.0.0.0/0 is deliberately rejected."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0") && alltrue([for cidr in var.endpoint_public_access_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Use valid, trusted CIDRs; 0.0.0.0/0 is not allowed."
  }
}

variable "node_instance_types" {
  description = "Allowed instance types for the Privacera managed node group. Multiple compatible types improve capacity availability."
  type        = list(string)
  default     = ["r5.2xlarge"]

  validation {
    condition     = length(var.node_instance_types) > 0
    error_message = "At least one node instance type is required."
  }
}

variable "node_min_size" {
  description = "Minimum managed-node count. The exercise requires scale-to-zero support."
  type        = number
  default     = 0
}

variable "node_desired_size" {
  description = "Initial desired managed-node count. One node limits development cost but is not highly available."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum managed-node count."
  type        = number
  default     = 3
}

variable "node_disk_size_gib" {
  description = "Encrypted gp3 root volume size in GiB."
  type        = number
  default     = 100

  validation {
    condition     = var.node_disk_size_gib >= 20
    error_message = "node_disk_size_gib must be at least 20 GiB."
  }
}

variable "control_plane_log_retention_days" {
  description = "CloudWatch retention period for all EKS control-plane log types."
  type        = number
  default     = 90

  validation {
    condition     = contains([30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.control_plane_log_retention_days)
    error_message = "control_plane_log_retention_days must be a CloudWatch Logs-supported retention value of at least 30 days."
  }
}

variable "additional_tags" {
  description = "Additional tags to merge onto all resources."
  type        = map(string)
  default     = {}
}
