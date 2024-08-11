# Provider configuration
provider "aws" {
  region = "ap-southeast-2"
}

# VPC configuration
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "amq-efs-poc-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "amq-efs-poc-igw"
  }
}

# Route table
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "amq-efs-poc-rt"
  }
}

# Subnet
resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-southeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name = "amq-efs-poc-subnet"
  }
}

# Route table association
resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

# Security group
resource "aws_security_group" "allow_amq" {
  name        = "allow_amq"
  description = "Allow AMQ inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "AMQ from VPC"
    from_port   = 61616
    to_port     = 61616
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NFS from VPC"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_amq"
  }
}

# EFS file system
resource "aws_efs_file_system" "amq_efs" {
  creation_token = "amq-efs"
  encrypted      = true

  tags = {
    Name = "amq-efs"
  }
}

# EFS mount target
resource "aws_efs_mount_target" "amq_efs_mount" {
  file_system_id  = aws_efs_file_system.amq_efs.id
  subnet_id       = aws_subnet.main.id
  security_groups = [aws_security_group.allow_amq.id]
}

# EFS access point
resource "aws_efs_access_point" "amq_efs_ap" {
  file_system_id = aws_efs_file_system.amq_efs.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/mq_data"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "0755"
    }
  }
}

# IAM Role for EC2 instances
resource "aws_iam_role" "ec2_efs_role" {
  name = "ec2_efs_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for EFS access
resource "aws_iam_role_policy" "efs_policy" {
  name = "efs_policy"
  role = aws_iam_role.ec2_efs_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:DescribeFileSystems"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_profile"
  role = aws_iam_role.ec2_efs_role.name
}

# EC2 instances
resource "aws_instance" "amq_node" {
  count                       = 2
  ami                         = "ami-02346a771f34de8ac"  # Amazon Linux 2 AMI for ap-southeast-2
  instance_type               = "t3.medium"
  key_name                    = "amq_key_pair"
  vpc_security_group_ids      = [aws_security_group.allow_amq.id]
  subnet_id                   = aws_subnet.main.id
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y amazon-efs-utils
              mkdir -p /mnt/efs
              echo "${aws_efs_file_system.amq_efs.dns_name}:/ /mnt/efs efs _netdev,tls,iam,accesspoint=${aws_efs_access_point.amq_efs_ap.id} 0 0" >> /etc/fstab
              mount -a
              EOF

  tags = {
    Name = "amq-node-${count.index + 1}"
  }

  depends_on = [aws_efs_mount_target.amq_efs_mount]
}

# Outputs
output "instance_public_ips" {
  value = aws_instance.amq_node[*].public_ip
}

output "efs_dns_name" {
  value = aws_efs_file_system.amq_efs.dns_name
}

output "efs_access_point_id" {
  value = aws_efs_access_point.amq_efs_ap.id
}