resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "django-ecs-vpc"
  }
}

resource "aws_subnet" "public" {
  count = 2
  vpc_id = aws_vpc.main.id
  cidr_block = "10.0.{count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "django-pubilc-${cound.index}" }
    
  
}
  
resource "aws_subnet" "private" {
  count = 2
  vpc_id = aws_vpc.main.id
  cidr_block = "{10.0.${count.index + 10}.0/24}"
  availability_zone = data.aws_availability_zones.available.name[count.index]
  tags = { Name = "django-private-${count.index}"}

}