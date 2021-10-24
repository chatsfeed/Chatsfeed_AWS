# We can set up multiple providers and use them for creating resources in different regions or in different AWS accounts by creating aliases.
# Some AWS services require the us-east-1 (N. Virginia) region to be configured:
# To use an ACM certificate with CloudFront, we must request or import the certificate in the US East (N. Virginia) region.
provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
  access_key = var.access_key
  secret_key = var.secret_key 
}

provider "aws" {
   region  = var.aws_region
   access_key = var.access_key
   secret_key = var.secret_key
}

# ------------------------------------------------------------------------------
# CONFIGURE TERRAFORM BACKEND
# ------------------------------------------------------------------------------
#terraform {
  #backend "s3" {
    # Replace this with your bucket name!
    #bucket         = "chatsfeed-terraform-s3-remote-state"
    #key            = "terraform.tfstate"
    #region  = "us-east-2"
    # Replace this with your DynamoDB table name!
    #dynamodb_table = "chatsfeed-terraform-dynamodb-remote-state-locks"
    #encrypt        = true
  #}

#}


## AWS Route53 is a DNS service used to perform three main functions: domain registration, DNS routing, and health checking.
# The first step to configure the DNS service for our domain (eg: example.com) is to create the public hosted zone 
# the name server (NS) record, and the start of a zone of authority (SOA) record are automatically created by AWS
resource  "aws_route53_zone" "main" {
  name         = var.website-domain
}


# We use ACM (AWS Certificate Manager) to create the wildcard certificate *.<yourdomain.com>
# This resource won't be created until we receive the email verifying we own the domain and we click on the confirmation link.
resource "aws_acm_certificate" "wildcard_website" {
  # We refer to the aliased provider ( ${provider_name}.${alias} ) for creating our ACM resource. 
  provider                  = aws.us-east-1
  # We want a wildcard cert so we can host subdomains later.
  domain_name       = "*.${var.website-domain}" 
  # We also want the cert to be valid for the root domain even though we'll be redirecting to the www. domain immediately.
  subject_alternative_names = ["${var.website-domain}"]
  # Which method to use for validation. DNS or EMAIL are valid, NONE can be used for certificates that were imported into ACM and then into Terraform. 
  validation_method         = "EMAIL"

  # (Optional) A mapping of tags to assign to the resource. 
  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Changed   = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
  })

  # The lifecycle block is available for all resource blocks regardless of type
  # create_before_destroy(bool), prevent_destroy(bool), and ignore_changes(list of attribute names)
  # to be used when a resource is created with references to data that may change in the future, but should not affect said resource after its creation 
  lifecycle {
    ignore_changes = [tags["Changed"]]
  }

}



# This resource is simply a waiter for manual email approval of ACM certificates.
# We use the aws_acm_certificate_validation resource to wait for the newly created certificate to become valid
# and then use its outputs to associate the certificate Amazon Resource Name (ARN) with the CloudFront distribution
# The certificate Amazon Resource Name (ARN) provided by aws_acm_certificate looks identical, but is almost always going to be invalid right away. 
# Using the output from the validation resource ensures that Terraform will wait for ACM to validate the certificate before resolving its ARN.
resource "aws_acm_certificate_validation" "wildcard_cert" {
  provider                = aws.us-east-1
  certificate_arn         = aws_acm_certificate.wildcard_website.arn
}


## Find a certificate that is issued
## Get the ARN of the issued certificate in AWS Certificate Manager (ACM)
data "aws_acm_certificate" "wildcard_website" {
  provider = aws.us-east-1

  # This argument is available for all resource blocks, regardless of resource type
  # Necessary when a resource or module relies on some other resource's behavior but doesn't access any of that resource's data in its arguments
  depends_on = [
    aws_acm_certificate.wildcard_website,
    aws_acm_certificate_validation.wildcard_cert,
  ]

  # (Required) The domain of the certificate to look up 
  domain      = "*.${var.website-domain}" #var.www-website-domain 
  # (Optional) A list of statuses on which to filter the returned list. Default is ISSUED if no value is specified
  # Valid values are PENDING_VALIDATION, ISSUED, INACTIVE, EXPIRED, VALIDATION_TIMED_OUT, REVOKED and FAILED 
  statuses    = ["ISSUED"]
  # Returning only the most recent one 
  most_recent = true
}

## CloudFront
# Creates the CloudFront distribution to serve the static website
resource "aws_cloudfront_distribution" "website_cdn_root" {
  enabled     = true
  # (Optional) - The price class for this distribution. One of PriceClass_All, PriceClass_200, PriceClass_100 
  price_class = "PriceClass_All"
  # (Optional) - Extra CNAMEs (alternate domain names), if any, for this distribution 
  aliases = [var.www-website-domain, var.app-website-domain]

  # Origin is where CloudFront gets its content from 
  origin {
    origin_id   = aws_alb.docker_demo_alb.id 
    domain_name = var.website-domain

    custom_origin_config {
      # The protocol policy that you want CloudFront to use when fetching objects from the origin server (a.k.a S3 in our situation). 
      # HTTP Only is the default setting when the origin is an Amazon S3 static website hosting endpoint
      # This is because Amazon S3 doesn’t support HTTPS connections for static website hosting endpoints. 
      origin_protocol_policy = "https-only"
      http_port            = 80
      https_port           = 443
      origin_ssl_protocols = ["SSLv3", "TLSv1.2", "TLSv1.1", "TLSv1"]
    }
  }

  #optional 
  #default_root_object = "index.html"

  logging_config {
    bucket = aws_s3_bucket.website_logs.bucket_domain_name
    prefix = "${var.www-website-domain}/"
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "DELETE"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    # This needs to match the `origin_id` above 
    target_origin_id = aws_alb.docker_demo_alb.id 
    min_ttl          = "0"
    default_ttl      = "300"
    max_ttl          = "1200"

    # Redirects any HTTP request to HTTPS 
    #viewer_protocol_policy = "redirect-to-https" 
    viewer_protocol_policy = "allow-all" 
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = data.aws_acm_certificate.wildcard_website.arn
    ssl_support_method  = "sni-only"
  }

  #optional 
  #custom_error_response {
    #error_caching_min_ttl = 300
    #error_code            = 404
    #response_page_path    = "/404.html"
    #response_code         = 404
  #}

  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Changed   = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
  })

  lifecycle {
    ignore_changes = [
      tags["Changed"],
      viewer_certificate,
    ]
  }
}


# Creates the DNS record to point on the main CloudFront distribution ID
resource "aws_route53_record" "website_cdn_root_record" {
  #zone_id = data.aws_route53_zone.wildcard_website.zone_id
  zone_id = "${aws_route53_zone.main.zone_id}"
  name    = var.www-website-domain
  type    = "A"

  alias {
    name = aws_cloudfront_distribution.website_cdn_root.domain_name
    zone_id = aws_cloudfront_distribution.website_cdn_root.hosted_zone_id
    evaluate_target_health = false
  }
}



# Creates bucket to store logs
resource "aws_s3_bucket" "website_logs" {
  bucket = "${var.www-website-domain}-logs"
  acl    = "log-delivery-write"

  # Comment the following line if you are uncomfortable with Terraform destroying the bucket even if this one is not empty
  force_destroy = true


  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Changed   = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
  })

  lifecycle {
    ignore_changes = [tags["Changed"]]
  }
}





# one vpc to hold them all, and in the cloud bind them
resource "aws_vpc" "demo" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "docker-nginx-demo-vpc"
  }
}

# let vpc talk to the internet - create internet gateway 
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.demo.id
  tags = {
    Name = "docker-nginx-demo-igw"
  }
}

# create one public subnet per availability zone
resource "aws_subnet" "public" {
  availability_zone       = "${element(var.azs,count.index)}"
  cidr_block              = "${element(var.public_subnets_cidr,count.index)}"
  count                   = "${length(var.azs)}"
  map_public_ip_on_launch = true
  vpc_id                  = aws_vpc.demo.id
  tags = {
    Name = "subnet-pub-${count.index}"
  }
}

# create one private subnet per availability zone
resource "aws_subnet" "private" {
  availability_zone       = "${element(var.azs,count.index)}"
  cidr_block              = "${element(var.private_subnets_cidr,count.index)}"
  count                   = "${length(var.azs)}"
  map_public_ip_on_launch = true
  vpc_id                  = aws_vpc.demo.id
  tags = {
    Name = "subnet-priv-${count.index}"
  }
}

# dynamic list of the public subnets created above
data "aws_subnet_ids" "public" {
  depends_on = [aws_subnet.public]
  vpc_id     = aws_vpc.demo.id
}

# dynamic list of the private subnets created above
data "aws_subnet_ids" "private" {
  depends_on = [aws_subnet.private]
  vpc_id     = aws_vpc.demo.id
}

# main route table for vpc and subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.demo.id
  tags = {
    Name = "public_route_table_main"
  }
}

# add public gateway to the route table
resource "aws_route" "public" {
  gateway_id             = aws_internet_gateway.gw.id
  destination_cidr_block = "0.0.0.0/0"
  route_table_id         = aws_route_table.public.id
}

# associate route table with vpc
resource "aws_main_route_table_association" "public" {
  vpc_id         = aws_vpc.demo.id
  route_table_id = aws_route_table.public.id
}

# and associate route table with each subnet
resource "aws_route_table_association" "public" {
  count           = "${length(var.azs)}"
  subnet_id      = element(data.aws_subnet_ids.public.ids, count.index)
  route_table_id = aws_route_table.public.id
}

# create elastic IP (EIP) to assign it the NAT Gateway 
resource "aws_eip" "demo_eip" {
  count    = length(var.azs)
  vpc      = true
  depends_on = [aws_internet_gateway.gw]
}

# create NAT Gateways
# make sure to create the nat in a internet-facing subnet (public subnet)
resource "aws_nat_gateway" "demo" {
    count    = length(var.azs)
    allocation_id = element(aws_eip.demo_eip.*.id, count.index)
    subnet_id = element(aws_subnet.public.*.id, count.index)
    depends_on = [aws_internet_gateway.gw]
}

# for each of the private ranges, create a "private" route table.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.demo.id
  count =length(var.azs) 
  tags = { 
    Name = "private_subnet_route_table_${count.index}"
  }
}

# add a nat gateway to each private subnet's route table
resource "aws_route" "private_nat_gateway_route" {
  count = length(var.azs)
  route_table_id = element(aws_route_table.private.*.id, count.index)
  destination_cidr_block = "0.0.0.0/0"
  depends_on = [aws_route_table.private]
  nat_gateway_id = element(aws_nat_gateway.demo.*.id, count.index)
}






# security group for application load balancer
resource "aws_security_group" "docker_demo_alb_sg" {
  name        = "docker-nginx-demo-alb-sg"
  description = "allow incoming HTTP traffic only"
  vpc_id      = aws_vpc.demo.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "alb-security-group-docker-demo"
  }
}

# using ALB - instances in private subnets
resource "aws_alb" "docker_demo_alb" {
  name                      = "docker-demo-alb"
  security_groups           = [aws_security_group.docker_demo_alb_sg.id]
  subnets                   = [aws_subnet.private.*.id]
  tags = {
    Name = "docker-demo-alb"
  }
}

# alb target group
resource "aws_alb_target_group" "docker-demo-tg" {
  name     = "docker-demo-alb-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.demo.id
  health_check {
    path = "/"
    port = 80
  }
}

# listener
resource "aws_alb_listener" "http_listener" {
  load_balancer_arn = aws_alb.docker_demo_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_alb_target_group.docker-demo-tg.arn
    type             = "forward"
  }
}

# target group attach
# using nested interpolation functions and the count parameter to the "aws_alb_target_group_attachment"
resource "aws_lb_target_group_attachment" "docker-demo" {
  count            = length(var.azs)
  target_group_arn = aws_alb_target_group.docker-demo-tg.arn
  target_id        =  element(split(",", join(",", aws_instance.docker_demo.*.id)), count.index)
  port             = 80
}

# ALB DNS is generated dynamically, return URL so that it can be used
output "url" {
  value = "http://${aws_alb.docker_demo_alb.dns_name}/"
}





resource "aws_security_group" "rds_security_group" {
  name        = "rds_security_group"
  description = "rds security group"
  vpc_id      = aws_vpc.demo.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/24"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rds_security_group"
  }
}

resource "aws_db_instance" "db" {
  engine            = var.rds_engine
  engine_version    = var.rds_engine_version
  identifier        = var.rds_identifier
  instance_class    = var.rds_instance_type
  allocated_storage = var.rds_storage_size
  name              = var.rds_db_name
  username          = var.rds_admin_user
  password          = var.rds_admin_password
  publicly_accessible    = var.rds_publicly_accessible
  vpc_security_group_ids = [aws_security_group.rds_security_group.id]
  final_snapshot_identifier = "demo-db-backup"
  skip_final_snapshot       = true

  # commented : if there is no default subnet, this will give us an error
  #db_subnet_group_name   = "rds_test"

  tags = {
    Name = "Postgres Database in ${var.aws_region}"
  }
}

resource "aws_db_subnet_group" "rds_test" {
  name       = "rds_test"
  count         = "3"
  subnet_ids                   = [aws_subnet.private.*.id]

}

output "postgress-address" {
  value = "address: ${aws_db_instance.db.address}"
}






# security group for EC2 instances
resource "aws_security_group" "docker_demo_ec2" {
  name        = "docker-nginx-demo-ec2"
  description = "allow incoming HTTP traffic only"
  vpc_id      = aws_vpc.demo.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 instances, one per availability zone
resource "aws_instance" "docker_demo" {
  ami                         = lookup(var.ec2_amis, var.aws_region)
  associate_public_ip_address = true
  count                       = length(var.azs)
  depends_on                  = [aws_subnet.private]
  instance_type               = "t2.micro"
  subnet_id                   = element(aws_subnet.private.*.id,count.index)
  user_data                   = file("user_data.sh")

  # references security group created above
  vpc_security_group_ids = [aws_security_group.docker_demo_ec2.id]

  tags = {
    Name = "docker-nginx-demo-instance-${count.index}"
  }
}












