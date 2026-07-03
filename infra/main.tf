terraform {
  backend "s3" {
    bucket         = "tf-state-bucket-henry-devops-123"
    key            = "k3s-cluster/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"]
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "target_subnet" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "${var.aws_region}a"
}

resource "random_id" "key_suffix" {
  byte_length = 4
}

resource "aws_security_group" "k3s_sg" {
  name        = "${var.project_name}-sg-${random_id.key_suffix.hex}"
  description = "Security group for K3s cluster"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30030
    to_port     = 30030
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

resource "tls_private_key" "k3s_crypto_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "k3s_key" {
  key_name   = "${var.project_name}-key-${random_id.key_suffix.hex}"
  public_key = tls_private_key.k3s_crypto_key.public_key_openssh
}

resource "aws_instance" "k3s_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"  
  subnet_id                   = data.aws_subnet.target_subnet.id
  vpc_security_group_ids      = [aws_security_group.k3s_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.k3s_key.key_name
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  
  user_data = base64encode(<<-SCRIPT
    #!/bin/bash
    set -e

    LOG="/var/log/user-data.log"
    echo "=== K3s Bootstrap Started at $(date) ===" > $LOG

    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab

    TOKEN=$(curl -s -m 5 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    PUBLIC_IP=$(curl -s -m 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s https://api.ipify.org)
    
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --tls-san=$PUBLIC_IP --bind-address=0.0.0.0 --disable=servicelb --disable=traefik --disable=metrics-server --write-kubeconfig-mode 644 --kubelet-arg=fail-swap-on=false" sh -
    
    systemctl enable k3s
    systemctl start k3s
  SCRIPT
  )

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "${var.project_name}-k3s-server" }
}   

output "ec2_public_ip" {
  description = "Public IP of the K3s server"
  value       = aws_instance.k3s_server.public_ip
}

output "k3s_private_key_pem" {
  description = "The generated private key content"
  value       = tls_private_key.k3s_crypto_key.private_key_openssh
  sensitive   = true
}