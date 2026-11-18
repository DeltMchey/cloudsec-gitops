variable "cluster_name" {
  description = "EKS cluster name used in resource names and discovery tags."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
}

variable "availability_zones" {
  description = "Exactly two caller-supplied AZ names."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "Exactly two public-subnet CIDRs."
  type        = list(string)
}
