# AWS provider
provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = "us-east-1"
}
# Azure provider
provider "azurerm" {
  features {}
  client_id       = var.azure_client_id
  client_secret   = var.azure_client_secret
  subscription_id = var.azure_subscription_id
  tenant_id       = var.azure_tenant_id
}

# Define an S3 bucket for static website hosting
resource "aws_s3_bucket" "weather_app" {
  bucket = "weather-tracker-app-bucket-784club912"

  website {
    index_document = "index.html"
    error_document = "error.html"
  }
  # Set bucket ownership controls
  lifecycle {
    prevent_destroy = true # Prevent accidental deletion
  }
}
resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket                  = aws_s3_bucket.weather_app.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}
# Upload website files to the S3 bucket
resource "aws_s3_object" "website_index" {
  bucket       = aws_s3_bucket.weather_app.id
  key          = "index.html"
  source       = "website/index.html"
  content_type = "text/html"
}
resource "aws_s3_object" "website_style" {
  bucket       = aws_s3_bucket.weather_app.id
  key          = "styles.css"
  source       = "website/styles.css"
  content_type = "text/css"
}
resource "aws_s3_object" "website_script" {
  bucket       = aws_s3_bucket.weather_app.id
  key          = "script.js"
  source       = "website/script.js"
  content_type = "application/javascript"
}
# Upload assets (images) to the S3 bucket
resource "aws_s3_object" "website_assets" {
  for_each = fileset("website/assets", "*")
  bucket   = aws_s3_bucket.weather_app.id
  key      = "assets/${each.value}"
  source   = "website/assets/${each.value}"
}
# Add a bucket policy to allow public read access
resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = aws_s3_bucket.weather_app.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "PublicReadGetObject",
        Effect    = "Allow",
        Principal = "*",
        Action    = "s3:GetObject",
        Resource  = "arn:aws:s3:::${aws_s3_bucket.weather_app.id}/*"
      },
      {
        Sid    = "CloudFrontLogsWrite",
        Effect = "Allow",
        Principal = {
          Service = "cloudfront.amazonaws.com"
        },
        Action   = "s3:PutObject",
        Resource = "arn:aws:s3:::${aws_s3_bucket.weather_app.id}/cloudfront-logs/*"
      }
    ]
  })
}
# Define Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "rg-static-website"
  location = "East US"
}
# Define Storage Account with Static Website
resource "azurerm_storage_account" "storage" {
  name                     = "mystorageecstatic3121"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  static_website {
    index_document = "index.html"
  }
}
# Upload index.html
resource "azurerm_storage_blob" "index_html" {
  name                   = "index.html"
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = "$web" # Static website container
  type                   = "Block"
  content_type           = "text/html"
  source                 = "website/index.html" # Path to local file
}
# Upload styles.css
resource "azurerm_storage_blob" "styles_css" {
  name                   = "styles.css"
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = "$web"
  type                   = "Block"
  content_type           = "text/css"
  source                 = "website/styles.css" # Path to local file
}
# Upload script.js
resource "azurerm_storage_blob" "scripts_js" {
  name                   = "script.js"
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = "$web"
  type                   = "Block"
  content_type           = "application/javascript"
  source                 = "website/script.js" # Path to local file
}
# Upload all assets in the assets folder
resource "azurerm_storage_blob" "assets" {
  for_each               = fileset("website/assets", "**/*")
  name                   = "assets/${each.value}"
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = "$web"
  type                   = "Block"
  content_type = lookup(
    {
      "png"  = "image/png"
      "jpg"  = "image/jpeg"
      "jpeg" = "image/jpeg"
      "gif"  = "image/gif"
      "svg"  = "image/svg+xml"
    },
    split(".", each.value)[length(split(".", each.value)) - 1],
    "application/octet-stream"
  )
  source = "website/assets/${each.value}" # Path to local assets
}
resource "aws_route53_zone" "main" {
  name = "hashemsweatherapp.site"
}
# CloudFront distribution in front of the S3 website
resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = ["hashemsweatherapp.site"]

  origin {
    domain_name = aws_s3_bucket.weather_app.website_endpoint
    origin_id   = "s3-website-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-website-origin"
    viewer_protocol_policy = "redirect-to-https"

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
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# Point the bare domain at CloudFront (simple, always-on record)
resource "aws_route53_record" "site" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "hashemsweatherapp.site"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

# ---------------------------------------------------------------
# FAILOVER SETUP (lives on www.hashemsweatherapp.site)
# Primary  -> CloudFront (AWS)
# Secondary-> Azure Storage static website
# Both records must share the same name and type for failover,
# and a CNAME is not allowed on the bare domain, so we use "www".
# ---------------------------------------------------------------

# Health check that watches the AWS/CloudFront side
resource "aws_route53_health_check" "aws_health_check" {
  type              = "HTTPS"
  fqdn              = aws_cloudfront_distribution.cdn.domain_name
  port              = 443
  request_interval  = 30
  failure_threshold = 3
}

# Health check that watches the Azure side
resource "aws_route53_health_check" "azure_health_check" {
  type              = "HTTPS"
  fqdn              = azurerm_storage_account.storage.primary_web_host
  port              = 443
  request_interval  = 30
  failure_threshold = 3
}

# PRIMARY: www -> CloudFront
resource "aws_route53_record" "primary" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www"
  type    = "CNAME"
  ttl     = 60

  records = [aws_cloudfront_distribution.cdn.domain_name]

  failover_routing_policy {
    type = "PRIMARY"
  }

  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.aws_health_check.id
}

# SECONDARY: www -> Azure static website
resource "aws_route53_record" "secondary" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www"
  type    = "CNAME"
  ttl     = 60

  records = [azurerm_storage_account.storage.primary_web_host]

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier  = "secondary"
  health_check_id = aws_route53_health_check.azure_health_check.id
}
