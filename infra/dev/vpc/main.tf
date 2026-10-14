locals {
  name = "${var.project_name}-${var.environment}"
  azs  = length(var.availability_zones) == 3 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 3)

  # Public /24s:       x.x.0-2.0/24
  # Application /20s: x.x.16.0/20, x.x.32.0/20, x.x.48.0/20
  # Database /24s:     x.x.64-66.0/24
  public_subnets   = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index)]
  private_subnets  = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index + 1)]
  database_subnets = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index + 64)]

  common_tags = merge(
    {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = var.project_name
      Repository  = "privacera-manager"
    },
    var.additional_tags,
  )

  interface_endpoint_services = toset([
    "autoscaling",
    "ec2",
    "ec2messages",
    "ecr.api",
    "ecr.dkr",
    "eks",
    "eks-auth",
    "elasticloadbalancing",
    "kms",
    "logs",
    "monitoring",
    "ssm",
    "ssmmessages",
    "sts",
  ])
}

data "aws_iam_policy_document" "flow_logs_kms" {
  statement {
    sid    = "EnableAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogsEncryption"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.${data.aws_partition.current.dns_suffix}"]
    }

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc-flow-log/*"]
    }
  }
}

resource "aws_kms_key" "flow_logs" {
  description             = "KMS key for ${local.name} VPC Flow Logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.flow_logs_kms.json

  tags = {
    Name = "${local.name}-vpc-flow-logs"
  }
}

resource "aws_kms_alias" "flow_logs" {
  name          = "alias/${local.name}-vpc-flow-logs"
  target_key_id = aws_kms_key.flow_logs.key_id
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets   = local.public_subnets
  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets

  public_subnet_suffix   = "public"
  private_subnet_suffix  = "application"
  database_subnet_suffix = "database"

  enable_dns_hostnames                 = true
  enable_dns_support                   = true
  enable_network_address_usage_metrics = true
  map_public_ip_on_launch              = false

  create_igw             = true
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []
  manage_default_route_table     = true
  default_route_table_routes     = []

  enable_flow_log                                 = true
  flow_log_traffic_type                           = "ALL"
  flow_log_max_aggregation_interval               = 60
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_name_prefix       = "/aws/vpc-flow-log/${local.name}/"
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = aws_kms_key.flow_logs.arn
  flow_log_cloudwatch_log_group_skip_destroy      = var.protect_flow_logs
  flow_log_cloudwatch_log_group_class             = "STANDARD"

  public_subnet_tags = {
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    Tier                                            = "public"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    Tier                                            = "application"
  }

  database_subnet_tags = {
    Tier = "database"
  }

  tags = local.common_tags
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "6.7.3"

  create     = var.enable_vpc_endpoints
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  create_security_group      = true
  security_group_name_prefix = "${local.name}-vpc-endpoints-"
  security_group_description = "Allow HTTPS from the application tier to private AWS service endpoints"
  security_group_rules = {
    for index, cidr in local.private_subnets : "https_from_application_${index}" => {
      description = "HTTPS from application subnet ${cidr}"
      cidr_blocks = [cidr]
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
    }
  }

  endpoints = merge(
    {
      s3 = {
        service         = "s3"
        service_type    = "Gateway"
        route_table_ids = module.vpc.private_route_table_ids
        tags            = { Name = "${local.name}-s3" }
      }
    },
    {
      for service in local.interface_endpoint_services : service => {
        service             = service
        private_dns_enabled = true
        tags                = { Name = "${local.name}-${replace(service, ".", "-")}" }
      }
    },
  )

  tags = local.common_tags
}
