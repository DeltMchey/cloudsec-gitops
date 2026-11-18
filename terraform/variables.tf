variable "aws_region" {
  description = "AWS region for the one-shot W9 validation."
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "Exactly two caller-supplied AZ names to keep planning offline."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2
    error_message = "Provide exactly two distinct availability zones."
  }
}

variable "cluster_name" {
  description = "Name of the disposable EKS cluster."
  type        = string
  default     = "secguard-w9"
}

variable "vpc_cidr" {
  description = "VPC CIDR; no NAT gateway is provisioned."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Two public-subnet CIDRs corresponding to availability_zones."
  type        = list(string)
  default     = ["10.20.0.0/20", "10.20.16.0/20"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2 && length(distinct(var.public_subnet_cidrs)) == 2
    error_message = "Provide exactly two distinct public subnet CIDRs."
  }
}

variable "node_instance_types" {
  description = "Instance types for the minimal managed node group."
  type        = list(string)
  default     = ["t3.medium"]

  validation {
    condition     = length(var.node_instance_types) > 0
    error_message = "At least one node instance type is required."
  }
}

variable "node_desired_size" {
  description = "Desired node count."
  type        = number
  default     = 1
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 2
}

variable "kubernetes_version" {
  description = "Optional EKS control-plane version. TODO(pin-at-execution): set a reviewed literal value for W9."
  type        = string
  default     = null
}

variable "offline_plan" {
  description = "Skip AWS provider credential, metadata, region and account checks for the no-refresh CI plan."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Default resource tags."
  type        = map(string)
  default = {
    Project     = "secguard"
    Environment = "w9-one-shot"
    ManagedBy   = "terraform"
  }
}
