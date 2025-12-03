# --- 1. Security Group cho EFS (Cho phép máy chủ EKS kết nối) ---
resource "aws_security_group" "efs_sg" {
  name        = "moodle-efs-sg"
  description = "Allow inbound NFS traffic from EKS Nodes"
  vpc_id      = aws_vpc.moodle_vpc.id

  # Cho phép kết nối vào cổng NFS (2049) từ mọi IP trong VPC
  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 2. Tạo File System (Ổ cứng mạng EFS) ---
resource "aws_efs_file_system" "moodle_efs" {
  creation_token = "moodle-efs-token"
  performance_mode = "generalPurpose"
  encrypted        = true # Bật mã hóa
  
  tags = {
    Name = "Moodle EFS Storage"
  }
}

# --- 3. Tạo Mount Target (Cắm dây mạng EFS vào 2 Subnet) ---
# EFS cần được cắm vào ít nhất 2 Subnet để các Node có thể kết nối.
resource "aws_efs_mount_target" "mt_1" {
  file_system_id  = aws_efs_file_system.moodle_efs.id
  subnet_id       = aws_subnet.public_1.id
  security_groups = [aws_security_group.efs_sg.id]
}

resource "aws_efs_mount_target" "mt_2" {
  file_system_id  = aws_efs_file_system.moodle_efs.id
  subnet_id       = aws_subnet.public_2.id
  security_groups = [aws_security_group.efs_sg.id]
}

# --- 4. Xuất ra ID của EFS để dùng trong K8s ---
output "efs_id" {
  value = aws_efs_file_system.moodle_efs.id
}