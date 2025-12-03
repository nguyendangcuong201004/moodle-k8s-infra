# 1. Tạo VPC (Mạng riêng ảo)
resource "aws_vpc" "moodle_vpc" {
  cidr_block           = "10.0.0.0/16" # Dải IP mạng: 65,536 địa chỉ
  enable_dns_hostnames = true          # Bắt buộc cho EKS
  enable_dns_support   = true

  tags = {
    Name = "moodle-vpc"
  }
}

# 2. Tạo Internet Gateway (Cổng ra Internet)
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.moodle_vpc.id

  tags = {
    Name = "moodle-igw"
  }
}

# 3. Tạo 2 Subnet Public (Để máy chủ kết nối được Internet)
# Subnet 1 (Zone a)
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

# Subnet 2 (Zone b) - EKS bắt buộc tối thiểu 2 Zone
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

# 4. Route Table (Bảng định tuyến ra Internet)
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

# 5. Gán Route Table vào Subnet
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public_rt.id
}