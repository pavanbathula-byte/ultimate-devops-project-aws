provider "aws" {
  region = "us-west-2"
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = "demo-terraform-eks-state-s3-bucket-pavan-9814"

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_eks_cluster" "eks" {
  name     = "demo-eks-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
      subnet_ids         = [aws_subnet.public1.id, aws_subnet.public2.id]  # both subnets in different AZs
    security_group_ids = [aws_security_group.cluster_sg.id]
  }

  # Optional: enable logging
  enabled_cluster_log_types = ["api", "audit", "authenticator"]
}

resource "aws_eks_node_group" "example" {
  cluster_name    = aws_eks_cluster.eks.name
  node_group_name = "example-nodes"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids = [aws_subnet.public2.id]  # only public subnet

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }
instance_types = ["t3.medium"] 
ami_type       = "AL2023_x86_64_STANDARD"
  version        = aws_eks_cluster.eks.version
}

resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}


# Attach required managed policies
resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ec2_container_registry" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_security_group_rule" "eks_nodes_to_cluster_https" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster_sg.id   # Cluster SG
  source_security_group_id = aws_security_group.node_sg.id      # Node SG
}

resource "aws_security_group_rule" "eks_nodes_to_cluster_kubelet" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster_sg.id   # Cluster SG
  source_security_group_id = aws_security_group.node_sg.id      # Node SG
}

# Security Group for EKS Cluster (control plane)
resource "aws_security_group" "cluster_sg" {
  name        = "eks-cluster-sg"
  description = "Cluster communication with worker nodes"
  vpc_id      = aws_vpc.main.id
}

# Security Group for Worker Nodes
resource "aws_security_group" "node_sg" {
  name        = "eks-nodes-sg"
  description = "Worker nodes"
  vpc_id      = aws_vpc.main.id

  # Allow all outbound (nodes can talk to internet)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM role for EKS cluster
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

# Attach required policies to the role
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_iam_role_policy_attachment" "eks_service_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.eks_cluster_role.name
}


resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "public1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-west-2a"
}

resource "aws_subnet" "public2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-west-2b"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
     version = ">= 5.50"
    }
  }

  backend "s3" {
    bucket         = "demo-terraform-eks-state-s3-bucket-pavan-9814"
    key            = "terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "terraform-eks-state-locks"
    encrypt        = true
  }
}


resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-eks-state-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
