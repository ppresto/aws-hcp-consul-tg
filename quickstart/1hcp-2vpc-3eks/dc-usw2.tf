data "aws_region" "usw2" {
  provider = aws.usw2
}
data "aws_availability_zones" "usw2" {
  provider = aws.usw2
  state    = "available"
}

data "aws_caller_identity" "usw2" {
  provider = aws.usw2
}

data "aws_iam_policy" "ebscsi-usw2" {
  provider = aws.usw2
  name     = "AmazonEBSCSIDriverPolicy"
}

# Create HVN and HCP Consul Cluster
module "hcp_consul_usw2" {
  providers = {
    aws = aws.usw2
  }
  source         = "../../modules/hcp_consul"
  for_each       = { for k, v in local.usw2 : k => v if contains(keys(v), "hcp-consul") }
  hvn_id         = try(local.usw2[each.key].hcp-consul.hvn_id, var.hvn_id)
  cloud_provider = try(local.usw2[each.key].hcp-consul.cloud_provider, var.cloud_provider)
  #region             = local.usw2[each.key].region
  cidr_block         = try(local.usw2[each.key].hcp-consul.cidr_block, var.hvn_cidr_block)
  cluster_id         = try(local.usw2[each.key].hcp-consul.cluster_id, var.cluster_id)
  tier               = try(local.usw2[each.key].hcp-consul.tier, "development")
  min_consul_version = try(local.usw2[each.key].hcp-consul.min_consul_version, var.min_consul_version)
  public_endpoint    = true
}

# Create usw2 VPCs defined in local.usw2
module "vpc-usw2" {
  # https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest
  providers = {
    aws = aws.usw2
  }
  source                   = "terraform-aws-modules/vpc/aws"
  version                  = "~> 3.0"
  for_each                 = local.usw2
  name                     = try(local.usw2[each.key].vpc.name, "${var.prefix}-${each.key}-vpc")
  cidr                     = local.usw2[each.key].vpc.cidr
  azs                      = [data.aws_availability_zones.usw2.names[0], data.aws_availability_zones.usw2.names[1]]
  private_subnets          = local.usw2[each.key].vpc.private_subnets
  public_subnets           = local.usw2[each.key].vpc.public_subnets
  enable_nat_gateway       = true
  single_nat_gateway       = true
  enable_dns_hostnames     = true
  enable_ipv6              = false
  default_route_table_name = "${var.prefix}-${each.key}-vpc1"

  # Cloudwatch log group and IAM role will be created
  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true

  flow_log_max_aggregation_interval         = 60
  flow_log_cloudwatch_log_group_name_prefix = "/aws/${local.usw2[each.key].vpc.name}"
  flow_log_cloudwatch_log_group_name_suffix = "flow"

  tags = {
    Terraform  = "true"
    Owner      = "${var.prefix}"
    transit_gw = "true"
  }
  private_subnet_tags = try(local.eks_private_tags[each.key],
    {
      Tier                              = "Private"
      "kubernetes.io/role/internal-elb" = 1
    })
  # {
  #   Tier                                                                              = "Private"
  #   "kubernetes.io/role/internal-elb"                                                 = 1
  #   #"kubernetes.io/cluster/${try(local.usw2[each.key].eks.cluster_name, var.prefix)}" = "shared"
  # }
  public_subnet_tags = try(local.eks_public_tags[each.key],
    {
      Tier                     = "Private"
      "kubernetes.io/role/elb" = 1
    })
  # {
  #   Tier                                                                              = "Public"
  #   "kubernetes.io/role/elb"                                                          = 1
  #   #"kubernetes.io/cluster/${try(local.usw2[each.key].eks.cluster_name, var.prefix)}" = "shared"
  # }
  default_route_table_tags = {
    Name = "${var.prefix}-vpc1-default"
  }
  private_route_table_tags = {
    Name = "${var.prefix}-vpc1-private"
  }
  public_route_table_tags = {
    Name = "${var.prefix}-vpc1-public"
  }
}

# Create 1+ Transit gateways to connect VPCs to the HVN
module "tgw-usw2" {
  # TransitGateway: https://registry.terraform.io/modules/terraform-aws-modules/transit-gateway/aws/latest
  providers = {
    aws = aws.usw2
  }
  source  = "terraform-aws-modules/transit-gateway/aws"
  version = "2.8.2"

  for_each                              = { for k, v in local.usw2 : k => v if contains(keys(v), "tgw") }
  description                           = "${var.prefix}-${each.key}-tgw - AWS Transit Gateway"
  name                                  = try(local.usw2[each.key].tgw.name, "${var.prefix}-${each.key}-tgw")
  enable_auto_accept_shared_attachments = try(local.usw2[each.key].tgw.enable_auto_accept_shared_attachments, true) # When "true" there is no need for RAM resources if using multiple AWS accounts
  ram_allow_external_principals         = try(local.usw2[each.key].tgw.ram_allow_external_principals, true)
  amazon_side_asn                       = 64532
  tgw_default_route_table_tags = {
    name = "${var.prefix}-${each.key}-tgw-default_rt"
  }
  tags = {
    project = "${var.prefix}-${each.key}-tgw"
  }
}

# Attach 1+ Transit Gateways to each VPC and create routes for the private subnets
module "tgw_vpc_attach_usw2" {
  source = "../../modules/aws_tgw_vpc_attach"
  providers = {
    aws = aws.usw2
  }
  #for_each = local.vpc_tgw_locations_map_usw2
  for_each           = local.tgw_vpc_attachments_map_usw2
  subnet_ids         = module.vpc-usw2[each.value.vpc_env].private_subnets
  transit_gateway_id = module.tgw-usw2[each.value.tgw_env].ec2_transit_gateway_id
  vpc_id             = module.vpc-usw2[each.value.vpc_env].vpc_id
  tags = {
    project = "${var.prefix}-${each.key}-tgw"
  }
}

# Attach HCP HVN to TGW and create routes from HVN to VPCs
module "aws_hcp_tgw_attach_usw2" {
  providers = {
    aws = aws.usw2
  }
  source                        = "../../modules/aws_hcp_tgw_attach"
  for_each                      = local.hvn_tgw_attachments_map_usw2
  ram_resource_share_name       = "${local.usw2[each.value.tgw_env].tgw.name}-ram"
  hvn_provider_account_id       = module.hcp_consul_usw2[each.value.hvn_env].provider_account_id
  tgw_resource_association_arn  = module.tgw-usw2[each.value.tgw_env].ec2_transit_gateway_arn
  hvn_id                        = module.hcp_consul_usw2[each.value.hvn_env].hvn_id
  transit_gateway_attachment_id = "${local.usw2[each.value.tgw_env].tgw.name}-id"
  transit_gateway_id            = module.tgw-usw2[each.value.tgw_env].ec2_transit_gateway_id
  # Define TGW private_route_cidr_list for specific routes, or use default list of all VPC routable_cidr_blocks
  hvn_route_cidr_list = try(local.usw2[each.value.hvn_env].hcp-consul.hvn_private_route_cidr_list, local.all_routable_cidr_blocks_usw2)
  hvn_link            = module.hcp_consul_usw2[each.value.hvn_env].hvn_self_link
  hvn_route_id        = var.prefix
}

# Create additional private routes between VPCs so they can see each other.
module "route_add_usw2" {
  source = "../../modules/aws_route_add"
  providers = {
    aws = aws.usw2
  }
  for_each               = local.vpc_routes_map_usw2
  route_table_id         = module.vpc-usw2[each.value.target_vpc].private_route_table_ids[0]
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = module.tgw-usw2[each.value.tgw_env].ec2_transit_gateway_id
  depends_on             = [module.tgw_vpc_attach_usw2]
}
#Add private routes to public route table to support SSH from bastion host.
module "route_public_add_usw2" {
  source = "../../modules/aws_route_add"
  providers = {
    aws = aws.usw2
  }
  for_each               = local.vpc_routes_map_usw2
  route_table_id         = module.vpc-usw2[each.value.target_vpc].public_route_table_ids[0]
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = module.tgw-usw2[each.value.tgw_env].ec2_transit_gateway_id
  depends_on             = [module.tgw_vpc_attach_usw2]
}
# Create static HVN route with local.usw2.usw2-shared.hcp-consul.cidr_block
module "route_add_hcp_usw2" {
  source = "../../modules/aws_route_add"
  providers = {
    aws = aws.usw2
  }
  for_each               = local.vpc_tgw_cidr_map_usw2
  route_table_id         = module.vpc-usw2[each.value.vpc_env].private_route_table_ids[0]
  destination_cidr_block = local.hvn_cidrs_map_usw2.hvn.cidr
  transit_gateway_id     = module.tgw-usw2[each.value.tgw_env].ec2_transit_gateway_id
  depends_on             = [module.aws_hcp_tgw_attach_usw2]
}

# Create EKS cluster per VPC defined in local.usw2
module "eks-usw2" {
  # https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
  providers = {
    aws = aws.usw2
  }
  source                          = "../../modules/aws_eks_cluster"
  for_each                        = local.eks_map_usw2
  cluster_name                    = try(local.eks_map_usw2[each.key].cluster_name, local.name)
  cluster_version                 = try(local.eks_map_usw2[each.key].eks_cluster_version, var.eks_cluster_version)
  cluster_endpoint_private_access = try(local.eks_map_usw2[each.key].cluster_endpoint_private_access, true)
  cluster_endpoint_public_access  = try(local.eks_map_usw2[each.key].cluster_endpoint_public_access, true)
  cluster_service_ipv4_cidr       = try(local.eks_map_usw2[each.key].service_ipv4_cidr, "172.20.0.0/16")
  min_size                        = try(local.eks_map_usw2[each.key].eks_min_size, var.eks_min_size)
  max_size                        = try(local.eks_map_usw2[each.key].eks_max_size, var.eks_max_size)
  desired_size                    = try(local.eks_map_usw2[each.key].eks_desired_size, var.eks_desired_size)
  vpc_id                          = module.vpc-usw2[each.value.vpc_env].vpc_id
  subnet_ids                      = module.vpc-usw2[each.value.vpc_env].private_subnets
  all_routable_cidrs              = local.all_routable_cidr_blocks_usw2
  hcp_cidr                        = [local.hvn_cidrs_map_usw2.hvn.cidr]
}
# # Add EKS cluster external tags to public subnets so AWS LB Controller can discover for external LB (ie: ingress to mesh)
# module "public_eks_cluster_tags-usw2" {
#   providers = {
#     aws = aws.usw2
#   }
#   source                          = "../../modules/aws_vpc_eks_cluster_tag"
#   for_each                        = local.eks_map_usw2
#   cluster_name                    = try(local.eks_map_usw2[each.key].cluster_name, local.name)
#   subnet_ids                      = module.vpc-usw2[each.value.vpc_env].public_subnets
# }

module "hcp_consul_policy-usw2" {

  providers = {
    aws    = aws.usw2
    consul = consul.usw2
  }
  source            = "../../modules/hcp_consul_policy"
  for_each          = toset(local.ec2_service_list_usw2)
  consul_datacenter = module.hcp_consul_usw2[local.hvn_list_usw2[0]].datacenter
  consul_service    = each.key

}
module "hcp_consul_ec2_iam_auth_method-usw2" {
  providers = {
    aws    = aws.usw2
    consul = consul.usw2
  }
  source                = "../../modules/hcp_consul_ec2_iam_auth_method"
  ServerIDHeaderValue   = join("", regex("http?s://(.*)", module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_private_endpoint_url))
  BoundIAMPrincipalARNs = [module.hcp_consul_ec2_iam_profile-usw2.instance_profile_arn]
}
module "hcp_consul_ec2_iam_profile-usw2" {
  # Create default ec2 profile used by consul agents
  providers = {
    aws = aws.usw2
  }
  source    = "../../modules/hcp_consul_ec2_iam_profile"
  role_name = "consul-usw2"
}
module "hcp_consul_ec2_client-usw2" {
  providers = {
    aws = aws.usw2
  }
  source   = "../../modules/hcp_consul_ec2_client"
  for_each = local.ec2_map_usw2

  hostname                        = local.ec2_map_usw2[each.key].hostname
  ec2_key_pair_name               = local.ec2_map_usw2[each.key].ec2_ssh_key
  vpc_id                          = module.vpc-usw2[each.value.vpc_env].vpc_id
  prefix                          = var.prefix
  associate_public_ip_address     = each.value.associate_public_ip_address
  subnet_id                       = each.value.target_subnets == "public_subnets" ? module.vpc-usw2[each.value.vpc_env].public_subnets[0] : module.vpc-usw2[each.value.vpc_env].private_subnets[0]
  security_group_ids              = [module.sg-consul-agents-usw2[each.value.vpc_env].securitygroup_id]
  consul_service                  = local.ec2_map_usw2[each.key].service
  instance_profile_name           = module.hcp_consul_ec2_iam_profile-usw2.instance_profile_name
  consul_acl_token_secret_id      = module.hcp_consul_policy-usw2[local.ec2_map_usw2[each.key].service].consul_service_api_token
  consul_datacenter               = module.hcp_consul_usw2[local.hvn_list_usw2[0]].datacenter
  consul_public_endpoint_url      = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_public_endpoint_url
  hcp_consul_ca_file              = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_ca_file
  hcp_consul_config_file          = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_config_file
  hcp_consul_root_token_secret_id = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_root_token_secret_id
}

module "sg-consul-agents-usw2" {
  providers = {
    aws = aws.usw2
  }
  source = "../../modules/aws_sg_consul_agents"
  #for_each              = local.usw2
  for_each = { for k, v in local.usw2 : k => v if contains(keys(v), "ec2") }
  #region                = local.usw2[each.key].region
  security_group_create = true
  name_prefix           = "${each.key}-consul-agent-sg"
  vpc_id                = module.vpc-usw2[each.key].vpc_id
  #vpc_cidr_block        = local.usw2[each.key].vpc.cidr
  vpc_cidr_blocks     = concat(local.all_routable_cidr_blocks_usw2, [local.usw2[local.hvn_list_usw2[0]].hcp-consul.cidr_block])
  private_cidr_blocks = local.all_routable_cidr_blocks_usw2
}

# module "sg-consul-dataplane-usw2" {
#   providers = {
#     aws = aws.usw2
#   }
#   source                = "../../modules/aws_sg_consul_dataplane"
#   for_each              = { for k, v in local.usw2 : k => v if contains(keys(v), "eks") }
#   security_group_create = true
#   name_prefix           = "${each.key}-consul-dataplane-sg" #eks-cluster-sg-${prefix}-${each.key}
#   vpc_id                = module.vpc-usw2[each.key].vpc_id
#   vpc_cidr_blocks       = concat(local.all_routable_cidr_blocks_usw2, [local.usw2[local.hvn_list_usw2[0]].hcp-consul.cidr_block])
#   private_cidr_blocks   = local.all_routable_cidr_blocks_usw2
# }

resource "local_file" "test" {
  for_each = local.eks_map_usw2
  content = templatefile("${path.module}/../templates/consul_helm_client.tmpl",
    {
      region_shortname            = "usw2"
      cluster_name                = try(local.eks_map_usw2[each.key].cluster_name, local.name)
      server_replicas             = try(local.eks_map_usw2[each.key].eks_desired_size, var.eks_desired_size)
      datacenter                  = module.hcp_consul_usw2[local.hvn_list_usw2[0]].datacenter
      release_name                = "consul-${each.key}"
      consul_external_servers     = jsondecode(base64decode(module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_config_file)).retry_join[0]
      eks_cluster_endpoint        = module.eks-usw2[each.key].cluster_endpoint
      consul_version              = var.consul_version
      consul_helm_chart_version   = var.consul_helm_chart_version
      consul_helm_chart_template  = try(local.eks_map_usw2[each.key].consul_helm_chart_template, var.consul_helm_chart_template)
      consul_chart_name           = "consul"
      consul_ca_file              = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_ca_file
      consul_config_file          = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_config_file
      consul_root_token_secret_id = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_root_token_secret_id
      consul_type                 = try(local.eks_map_usw2[each.key].consul_type, "dataplane")
      partition                   = try(local.eks_map_usw2[each.key].consul_partition, var.consul_partition)
      node_selector               = "" #K8s node label to target deployment too.
  })
  filename = "${path.module}/consul_helm_values/auto-${local.eks_map_usw2[each.key].cluster_name}.tf"
}

output "usw2_regions" {
  value = { for k, v in local.usw2 : k => data.aws_region.usw2.name }
  #value = data.aws_region.usw2.name
}
# output "usw2_regions" {
#   value = { for k, v in local.usw2 : k => local.usw2[k].region }
# }
output "usw2_projects" { # Used by ./scripts/kubectl_connect_eks.sh to loop through Proj/Env and Auth to EKS clusters
  value = [for proj in sort(keys(local.usw2)) : proj]
}
# VPC
output "usw2_vpc_ids" {
  value = { for env in sort(keys(local.usw2)) : env => module.vpc-usw2[env].vpc_id }
}

### EKS
output "usw2_eks_cluster_endpoints" {
  description = "Endpoint for your Kubernetes API server"
  value       = { for k, v in local.eks_map_usw2 : k => module.eks-usw2[k].cluster_endpoint }
}
output "usw2_eks_cluster_names" {
  description = "The name/id of the EKS cluster. Will block on cluster creation until the cluster is really ready"
  value       = { for k, v in local.eks_map_usw2 : k => module.eks-usw2[k].cluster_name }
}
output "usw2_eks_cluster_names_to_region" {
  description = "The name/id of the EKS cluster. Will block on cluster creation until the cluster is really ready"
  value       = { for k, v in local.eks_map_usw2 : module.eks-usw2[k].cluster_name => data.aws_region.usw2.name }
}
# ### EKS
# output "usw2_eks_cluster_endpoints" {
#   description = "Endpoint for your Kubernetes API server"
#   value       = { for k, v in local.usw2 : k => module.eks-usw2[k].cluster_endpoint if contains(keys(v), "eks") }
# }
# output "usw2_eks_cluster_names" {
#   description = "The name/id of the EKS cluster. Will block on cluster creation until the cluster is really ready"
#   value       = { for k, v in local.usw2 : k => local.usw2[k].eks.cluster_name if contains(keys(v), "eks") }
# }
### Transit Gateway
output "usw2_ec2_transit_gateway_arn" {
  description = "EC2 Transit Gateway Amazon Resource Name (ARN)"
  value       = { for k, v in local.usw2 : k => module.tgw-usw2[k].ec2_transit_gateway_arn if contains(keys(v), "tgw") }
}

output "usw2_ec2_transit_gateway_id" {
  description = "EC2 Transit Gateway identifier"
  value       = { for k, v in local.usw2 : k => module.tgw-usw2[k].ec2_transit_gateway_id if contains(keys(v), "tgw") }
}

output "usw2_default_hvn_routes" {
  description = "A list of every VPCs routable cidr blocks are added to HVN Route unless (hcp-consul.hvn_private_route_cidr_list) is defined"
  value       = [for hvn_route in local.all_routable_cidr_blocks_usw2 : hvn_route]
}
output "usw2_vpc-tgw-cidr_routes_added" {
  value = [for vpc_route in sort(keys(local.vpc_routes_map_usw2)) : vpc_route]
}
output "usw2_ec2_ip" {
  value = { for k, v in local.ec2_map_usw2 : k => module.hcp_consul_ec2_client-usw2[k].ec2_ip }
}
output "usw2_consul_config_file" {
  value = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_config_file
}
output "usw2_consul_ca_file" {
  value = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_ca_file
}
output "usw2_consul_private_endpoint_url" {
  value = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_private_endpoint_url
}
output "usw2_consul_root_token_secret_id" {
  value = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_root_token_secret_id
}
output "usw2_consul_service_api_token" {
  value = [for svc in local.ec2_service_list_usw2 : module.hcp_consul_policy-usw2[svc].consul_service_api_token]
}
output "usw2_retry_join" {
  value = jsondecode(base64decode(module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_config_file)).retry_join[0]
}
output "usw2_consul_public_endpoint_url" {
  value = module.hcp_consul_usw2[local.hvn_list_usw2[0]].consul_public_endpoint_url
}

output "usw2_consul_ec2_iam_arn" {
  value = module.hcp_consul_ec2_iam_profile-usw2.instance_profile_arn
}
output "usw2_hcp_consul_ec2_iam_auth_config" {
  value = module.hcp_consul_ec2_iam_auth_method-usw2.config_json
}