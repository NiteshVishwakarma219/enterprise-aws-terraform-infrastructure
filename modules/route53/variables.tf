variable "enabled" {
  description = "Whether Route 53 DNS and ACM resources should be created."
  type        = bool
}

variable "zone_name" {
  description = "Authoritative Route 53 hosted zone name, e.g. nitesh.shop"
  type        = string
}

variable "domain_name" {
  description = "Public application hostname, e.g. nitesh.shop or app.nitesh.shop"
  type        = string
}
