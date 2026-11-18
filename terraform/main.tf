module "network" {
  source = "./modules/network"

  cluster_name        = var.cluster_name
  vpc_cidr            = var.vpc_cidr
  availability_zones  = var.availability_zones
  public_subnet_cidrs = var.public_subnet_cidrs
}

module "eks" {
  source = "./modules/eks"

  cluster_name        = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  subnet_ids          = module.network.public_subnet_ids
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}
