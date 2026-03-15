resource "aws_security_group" "efs_sg" {
  name        = "moodle-efs-sg"
  description = "Allow inbound NFS traffic from EKS Nodes"
  vpc_id      = aws_vpc.moodle_vpc.id

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

resource "aws_efs_file_system" "moodle_efs" {
  creation_token = "moodle-efs-token"
  performance_mode = "generalPurpose"
  encrypted        = true

  tags = {
    Name = "Moodle EFS Storage"
  }
}

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

# EFS Access Points for environment isolation
resource "aws_efs_access_point" "prod" {
  file_system_id = aws_efs_file_system.moodle_efs.id

  posix_user {
    uid = 33 # www-data
    gid = 33
  }

  root_directory {
    path = "/prod/moodledata"
    creation_info {
      owner_uid   = 33
      owner_gid   = 33
      permissions = "0777"
    }
  }

  tags = {
    Name = "moodle-efs-prod"
  }
}

resource "aws_efs_access_point" "staging" {
  file_system_id = aws_efs_file_system.moodle_efs.id

  posix_user {
    uid = 33
    gid = 33
  }

  root_directory {
    path = "/staging/moodledata"
    creation_info {
      owner_uid   = 33
      owner_gid   = 33
      permissions = "0777"
    }
  }

  tags = {
    Name = "moodle-efs-staging"
  }
}

output "efs_id" {
  value = aws_efs_file_system.moodle_efs.id
}

output "efs_access_point_prod_id" {
  value = aws_efs_access_point.prod.id
}

output "efs_access_point_staging_id" {
  value = aws_efs_access_point.staging.id
}