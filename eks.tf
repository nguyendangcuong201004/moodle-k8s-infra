# --- 1. IAM Role cho Cluster (Quyền để EKS điều khiển AWS) ---
resource "aws_iam_role" "eks_cluster_role" {
  name = "moodle-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

# --- 2. EKS CLUSTER (Máy chủ điều khiển - Master) ---
resource "aws_eks_cluster" "moodle_cluster" {
  name     = "moodle-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    # Kết nối vào 2 subnet public mà bạn đã tạo ở file vpc.tf
    subnet_ids = [
      aws_subnet.public_1.id,
      aws_subnet.public_2.id
    ]
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# --- 3. IAM Role cho Node (Máy con - Worker) ---
resource "aws_iam_role" "eks_node_role" {
  name = "moodle-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Gán quyền cho Node
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_role.name
}

# --- 4. NODE GROUP (Tạo các máy ảo thật để chạy Moodle) ---
resource "aws_eks_node_group" "moodle_nodes" {
  cluster_name    = aws_eks_cluster.moodle_cluster.name
  node_group_name = "moodle-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = [aws_subnet.public_1.id, aws_subnet.public_2.id]

  scaling_config {
    desired_size = 2  # Chạy 2 máy
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.micro"] 

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry,
  ]
}

# --- 5. IAM Role cho EFS CSI Driver (Theo yêu cầu AWS Add-on) ---
resource "aws_iam_role" "efs_csi_role" {
  name = "moodle-efs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.moodle_cluster.identity[0].oidc[0].issuer, "https://", "")}"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(data.aws_eks_cluster.moodle_cluster.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:efs-csi-controller-sa"
        }
      }
    }]
  })
}

# Gán chính sách EFS Driver Policy cho Role
resource "aws_iam_role_policy_attachment" "efs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
  role       = aws_iam_role.efs_csi_role.name
}

# 6. Xuất ra ARN của Role EFS (Để dùng trong AWS CLI)
output "efs_csi_role_arn" {
  value = aws_iam_role.efs_csi_role.arn
}


data "aws_eks_cluster" "moodle_cluster" {
  name = aws_eks_cluster.moodle_cluster.name
}

data "aws_caller_identity" "current" {}