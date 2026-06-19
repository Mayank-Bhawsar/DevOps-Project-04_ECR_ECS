data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support = true

  tags = {
    Name = "devops-project-04-vpc"
  }
}

resource "aws_subnet" "public" {
  count = 2
  vpc_id = aws_vpc.main.id
  cidr_block = "10.0.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "devops-04-public-subnet-${count.index + 1}"
  }
}

resource "aws_subnet" "private" {
  count = 2
  vpc_id = aws_vpc.main.id
  cidr_block = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "devops-04-private-subnet-${count.index + 1}"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "devops-04-igw"
  }
}

resource "aws_security_group" "nat_sg" {
  name = "devops-04-nat-sg"
  description = "Allow private subnet to route traffic through this instance"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "devops-04-nat-sg"
  }
}
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners = ["amazon"]

  filter {
    name = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "nat_instance" {
  ami = data.aws_ami.amazon_linux_2023.id
  instance_type = "t3.micro"
  subnet_id = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.nat_sg.id]

  source_dest_check = false

  user_data = <<-EOF
              #!/bin/bash
              sysctl -w net.ipv4.ip_forward=1
              echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
              dnf install iptables -y
              iptables -t nat -A POSTROUTING -o x86_64 -j MASQUERADE
              EOF

  tags = {
    Name = "devops-04-nat-instance"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "devops-04-public-rt"
  }

}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    network_interface_id = aws_instance.nat_instance.primary_network_interface_id
  }
  tags = {
    Name = "devops-04-private-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = 2
  subnet_id = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = 2
  subnet_id = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
