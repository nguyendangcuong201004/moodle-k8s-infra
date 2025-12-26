resource "aws_db_subnet_group" "moodle_db_subnet_group" {
  name       = "moodle-db-subnet-group"
  subnet_ids = [aws_subnet.public_1.id, aws_subnet.public_2.id]

  tags = { Name = "Moodle DB Subnet Group" }
}

resource "aws_security_group" "rds_sg" {
  name        = "moodle-rds-sg"
  description = "Allow inbound traffic for Postgres"
  vpc_id      = aws_vpc.moodle_vpc.id

  # Cho phép các máy trong VPC vào cổng 5432
  ingress {
    from_port   = 5432
    to_port     = 5432
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

resource "aws_db_instance" "moodle_db" {
  identifier             = "moodle-db-postgres"
  engine                 = "postgres"
  engine_version         = "16.6"
  instance_class         = "db.t3.micro" # Loại miễn phí
  allocated_storage      = 20
  storage_type           = "gp2"
  
  db_name                = "moodle"
  username               = "moodleuser"
  password               = "Anhmeow123" 

  db_subnet_group_name   = aws_db_subnet_group.moodle_db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  publicly_accessible    = true
  skip_final_snapshot    = true
  
  tags = { Name = "Moodle RDS" }
}

output "rds_endpoint" {
  value = aws_db_instance.moodle_db.endpoint
}