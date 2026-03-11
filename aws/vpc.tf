resource "aws_vpc" "moodle_vpc" {
  cidr_block           = "10.0.0.0/16" # Dải IP mạng: 65,536 địa chỉ
  enable_dns_hostnames = true          # Bắt buộc cho EKS
  enable_dns_support   = true

  tags = {
    Name = "moodle-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.moodle_vpc.id

  tags = {
    Name = "moodle-igw"
  }
}

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.moodle_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-southeast-1a"
  map_public_ip_on_launch = true # Tự cấp IP công khai

  tags = {
    Name                        = "moodle-public-1"
    "kubernetes.io/role/elb"    = "1" # Tag này để EKS biết đường tạo Load Balancer
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.moodle_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-southeast-1b"
  map_public_ip_on_launch = true

  tags = {
    Name                        = "moodle-public-2"
    "kubernetes.io/role/elb"    = "1"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.moodle_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "moodle-public-rt"
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public_rt.id
}