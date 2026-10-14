variable "aws_region" {
  description = "AWS Region in which to create the development VPC."
  type        = string
  default     = "ap-southeast-2"
}

variable "aws_profile" {
  description = "AWS shared-config profile used by the provider. Set to null for environment, role, or workload credentials."
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
  description = "Short project identifier used in resource names and tags."
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

variable "eks_cluster_name" {
  description = "EKS cluster name used for Kubernetes subnet discovery tags."
  type        = string
  default     = "privacera-cluster"

  validation {
    condition     = var.eks_cluster_name == "privacera-cluster"
    error_message = "The required development EKS cluster name is privacera-cluster."
  }
}

variable "vpc_cidr" {
  description = "IPv4 /16 CIDR for the VPC. The generated subnet layout creates three /20 application subnets and six /24 edge/data subnets."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 8, 66)) && try(tonumber(split("/", var.vpc_cidr)[1]) == 16, false)
    error_message = "vpc_cidr must be a valid IPv4 /16 CIDR for the generated three-tier subnet layout."
  }
}

variable "availability_zones" {
  description = "Exactly three availability zones. Leave empty to use the first three standard AZs in the selected Region."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) == 3
    error_message = "availability_zones must be empty or contain exactly three AZ names."
  }
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway to reduce dev cost. The secure/resilient default creates one NAT gateway per AZ."
  type        = bool
  default     = false
}

variable "enable_vpc_endpoints" {
  description = "Create private endpoints for the AWS services used by EKS and common controllers. Interface endpoints incur hourly and data-processing charges."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention period for VPC Flow Logs."
  type        = number
  default     = 90

  validation {
    condition     = contains([30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_log_retention_days)
    error_message = "flow_log_retention_days must be a CloudWatch Logs-supported retention value of at least 30 days."
  }
}

variable "protect_flow_logs" {
  description = "Retain the VPC Flow Log group when the stack is destroyed. Remove/import it manually when intentional deletion is required."
  type        = bool
  default     = true
}

variable "additional_tags" {
  description = "Additional tags to merge onto all resources."
  type        = map(string)
  default     = {}
}
