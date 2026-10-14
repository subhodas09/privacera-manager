locals {
  cluster_name = var.cluster_name

  common_tags = merge(
    {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = var.project_name
      Repository  = "privacera-manager"
    },
    var.additional_tags,
  )

  vpc_state_config = merge(
    {
      bucket = var.vpc_state_bucket
      key    = var.vpc_state_key
      region = var.vpc_state_region
    },
    var.aws_profile == null ? {} : { profile = var.aws_profile },
    var.vpc_state_kms_key_id == null ? {} : { kms_key_id = var.vpc_state_kms_key_id },
    var.vpc_state_role_arn == null ? {} : { assume_role = { role_arn = var.vpc_state_role_arn } },
  )

  access_entries = {
    for index, principal_arn in sort(tolist(var.cluster_admin_principal_arns)) : "administrator-${index}" => {
      principal_arn = principal_arn
      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}

data "terraform_remote_state" "vpc" {
  backend = "s3"
  config  = local.vpc_state_config
}

data "aws_iam_policy_document" "eks_kms" {
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
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${local.cluster_name}/cluster*"]
    }
  }
}

resource "aws_kms_key" "eks" {
  description             = "KMS key for ${local.cluster_name} Kubernetes secrets and control-plane logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.eks_kms.json

  tags = {
    Name = "${local.cluster_name}-eks"
  }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

data "aws_iam_policy_document" "pod_identity_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

resource "aws_iam_role" "vpc_cni" {
  name               = "${local.cluster_name}-vpc-cni"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json
  description        = "Least-privilege Pod Identity role for the EKS VPC CNI add-on"
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json
  description        = "Least-privilege Pod Identity role for the EKS EBS CSI add-on"
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.26.0"

  name                = local.cluster_name
  kubernetes_version  = var.kubernetes_version
  deletion_protection = true

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false
  access_entries                           = local.access_entries

  vpc_id                   = data.terraform_remote_state.vpc.outputs.vpc_id
  subnet_ids               = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  control_plane_subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids

  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access ? var.endpoint_public_access_cidrs : null

  enabled_log_types                      = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.control_plane_log_retention_days
  cloudwatch_log_group_kms_key_id        = aws_kms_key.eks.arn
  cloudwatch_log_group_class             = "STANDARD"

  create_kms_key = false
  encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  upgrade_policy = {
    # Privacera 9.0.29.1 supports Kubernetes only up to 1.32, which is now in
    # EKS extended support. Upgrade Privacera before this version reaches EOL.
    support_type = "EXTENDED"
  }

  zonal_shift_config = {
    enabled = true
  }

  # This organization denies iam:CreateOpenIDConnectProvider through an SCP.
  # All add-ons in this stack use EKS Pod Identity, so IRSA is not required.
  enable_irsa = false

  addons = {
    coredns = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      before_compute = true
      most_recent    = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      before_compute = true
      most_recent    = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
      pod_identity_association = [{
        role_arn        = aws_iam_role.vpc_cni.arn
        service_account = "aws-node"
      }]
    }
    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  node_security_group_enable_recommended_rules = true

  eks_managed_node_groups = {
    privacera = {
      ami_type                       = "AL2023_x86_64_STANDARD"
      use_latest_ami_release_version = true
      capacity_type                  = "ON_DEMAND"
      instance_types                 = var.node_instance_types
      subnet_ids                     = data.terraform_remote_state.vpc.outputs.private_subnet_ids

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size

      enable_monitoring          = true
      iam_role_attach_cni_policy = false
      node_repair_config = {
        enabled = true
      }

      update_config = {
        max_unavailable_percentage = 33
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
        instance_metadata_tags      = "disabled"
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            encrypted             = true
            delete_on_termination = true
            volume_type           = "gp3"
            volume_size           = var.node_disk_size_gib
            iops                  = 3000
            throughput            = 125
          }
        }
      }

      labels = {
        workload = "privacera"
      }

      tags = {
        Name = "${local.cluster_name}-privacera"
      }
    }
  }

  tags = local.common_tags
}

resource "terraform_data" "guardrails" {
  lifecycle {
    precondition {
      condition     = var.node_min_size == 0 && var.node_max_size == 3 && var.node_desired_size >= var.node_min_size && var.node_desired_size <= var.node_max_size
      error_message = "The required development node range is min_size=0 and max_size=3; desired_size must remain within that range."
    }

    precondition {
      condition     = !var.endpoint_public_access || length(var.endpoint_public_access_cidrs) > 0
      error_message = "When endpoint_public_access is true, provide at least one trusted endpoint_public_access_cidrs entry."
    }
  }
}
