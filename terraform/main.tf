terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # Using a recent version of the AWS provider
    }
  }

  backend "s3" {
    # YOU MUST MANUALLY CREATE THIS S3 BUCKET AND REGION BEFORE RUNNING 'terraform init'
    bucket = "ddavid-io-tfstate-20250510" # Replace if you chose a different name
    key    = "ddavid.io/portfolio-website.tfstate"
    region = "us-east-1" # As you specified
    encrypt = true
    # dynamodb_table = "" # You mentioned no DynamoDB table for locking
  }
}

provider "aws" {
  region = "us-east-1" # Your primary AWS region
}

# Provider alias for ACM certificate which must be in us-east-1
# Since your primary region is also us-east-1, this specific alias for ACM isn't strictly
# necessary here but is good practice if your primary region was different.
provider "aws" {
  alias  = "us_east_1_for_acm"
  region = "us-east-1"
}

# ------------------------------------------------------------------------------
# DNS (Route 53 Hosted Zone)
# ------------------------------------------------------------------------------
resource "aws_route53_zone" "primary_hosted_zone" {
  name = "ddavid.io" # Your domain name
}

# Output the nameservers to configure in Namecheap
output "route53_name_servers" {
  description = "Name servers for the Route 53 hosted zone. Configure these in Namecheap."
  value       = aws_route53_zone.primary_hosted_zone.name_servers
}

# ------------------------------------------------------------------------------
# ACM Certificate for HTTPS
# ------------------------------------------------------------------------------
resource "aws_acm_certificate" "site_certificate" {
  provider                  = aws.us_east_1_for_acm # Ensures cert is in us-east-1
  domain_name               = "ddavid.io"           # Your domain name
  # subject_alternative_names = [] # You specified "None"
  validation_method         = "DNS"

  tags = {
    Name        = "ddavid.io-certificate"
    Environment = "Production"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate_validation_records" {
  # Create DNS records for ACM certificate validation
  # Uses the default AWS provider (us-east-1, as per your primary region)
  for_each = {
    for dvo in aws_acm_certificate.site_certificate.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true # Useful if records might already exist for some reason
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.primary_hosted_zone.zone_id
}

resource "aws_acm_certificate_validation" "certificate_validation" {
  provider                = aws.us_east_1_for_acm # Validation must also reference the cert's region
  certificate_arn         = aws_acm_certificate.site_certificate.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation_records : record.fqdn]
}

# ------------------------------------------------------------------------------
# S3 Bucket for Static Website Hosting
# ------------------------------------------------------------------------------
locals {
  # S3 bucket name - replace if you want a different name
  s3_website_bucket_name = "ddavid-io-portfolio-files"
}

resource "aws_s3_bucket" "website_bucket" {
  bucket = local.s3_website_bucket_name

  tags = {
  Name        = "Portfolio-Site-Bucket-ddavid-io"
  Environment = "Production"
  }
}

resource "aws_s3_bucket_website_configuration" "website_configuration" {
  bucket = aws_s3_bucket.website_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html" # You'll need to create an error.html in your site
  }
}

resource "aws_s3_bucket_public_access_block" "website_public_access_block" {
  bucket = aws_s3_bucket.website_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------------
# CloudFront Distribution
# ------------------------------------------------------------------------------

# CloudFront Origin Access Control (OAC) for S3
resource "aws_cloudfront_origin_access_control" "s3_origin_access_control" {
  name                              = "oac-s3-${local.s3_website_bucket_name}"
  description                       = "Origin Access Control for S3 bucket ${local.s3_website_bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# S3 Bucket Policy to allow CloudFront access via OAC
resource "aws_s3_bucket_policy" "website_bucket_policy" {
  bucket = aws_s3_bucket.website_bucket.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = { Service = "cloudfront.amazonaws.com" },
        Action    = "s3:GetObject",
        Resource  = "${aws_s3_bucket.website_bucket.arn}/*",
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.s3_distribution.arn
          }
        }
      }
    ]
  })
}

resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name              = aws_s3_bucket.website_bucket.bucket_regional_domain_name
    origin_id                = "S3-${local.s3_website_bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3_origin_access_control.id
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudFront distribution for ddavid.io portfolio"
  default_root_object = "index.html"

  # Since you specified "None" for SANs, the certificate only covers "ddavid.io".
  # Therefore, CloudFront should only have "ddavid.io" as an alias.
  aliases = ["ddavid.io"]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${local.s3_website_bucket_name}"

    # Forward query strings and cookies if your static site needs them,
    # otherwise 'none' is better for caching.
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https" # Redirect HTTP to HTTPS
    min_ttl                = 0
    default_ttl            = 3600  # 1 hour
    max_ttl                = 86400 # 24 hours
    compress               = true # Enable compression for faster loading
  }

  # For best performance and cost, choose an appropriate price class.
  # PriceClass_100: USA, Canada, Europe
  # PriceClass_200: PriceClass_100 + Asia, Middle East, Africa
  # PriceClass_All: All regions (best performance, highest cost)
  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "none" # No geo-restrictions by default
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.site_certificate.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021" # Recommended for security
  }

  # Optional: Logging (recommended for production)
  # logging_config {
  #   include_cookies = false
  #   bucket          = "your-cloudfront-logs-bucket-name.s3.amazonaws.com" # Create a separate S3 bucket for logs
  #   prefix          = "ddavid.io-cloudfront-logs/"
  # }

  tags = {
    Name        = "ddavid.io-portfolio-cdn"
    Environment = "Production"
  }
}

# ------------------------------------------------------------------------------
# Route 53 Alias Record to point your domain to CloudFront
# ------------------------------------------------------------------------------
resource "aws_route53_record" "apex_domain_to_cloudfront" {
  zone_id = aws_route53_zone.primary_hosted_zone.zone_id
  name    = "ddavid.io" # Your apex domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
    evaluate_target_health = false # Recommended for alias records pointing to CloudFront
  }
}

# IPv6 Alias Record
resource "aws_route53_record" "apex_domain_to_cloudfront_aaaa" {
  zone_id = aws_route53_zone.primary_hosted_zone.zone_id
  name    = "ddavid.io"
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------
output "website_s3_bucket_name" {
  description = "Name of the S3 bucket hosting the static website files."
  value       = aws_s3_bucket.website_bucket.bucket
}

output "cloudfront_distribution_id" {
  description = "ID of the CloudFront distribution."
  value       = aws_cloudfront_distribution.s3_distribution.id
}

output "cloudfront_domain_name" {
  description = "Domain name of the CloudFront distribution."
  value       = aws_cloudfront_distribution.s3_distribution.domain_name
}

output "website_url" {
  description = "The URL of your portfolio website."
  value       = "https://${aws_route53_record.apex_domain_to_cloudfront.name}"
}