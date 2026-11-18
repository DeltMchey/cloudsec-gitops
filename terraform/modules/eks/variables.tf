variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "Optional pinned EKS version; null leaves provider selection until the execution pin is supplied."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Public subnet IDs for control-plane ENIs and managed nodes."
  type        = list(string)
}

variable "node_instance_types" {
  description = "Managed node instance types."
  type        = list(string)
}

variable "node_desired_size" {
  description = "Desired node count."
  type        = number
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
}
