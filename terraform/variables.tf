variable "aws_region" {
  description = "AWS region to deploy in"
  type        = string
  default     = "us-east-1"
}

variable "os_variant" {
  description = "OS to use: 'ubuntu' (Ubuntu 22.04) or 'rhel' (Rocky Linux 9)"
  type        = string
  default     = "ubuntu"

  validation {
    condition     = contains(["ubuntu", "rhel"], var.os_variant)
    error_message = "os_variant must be 'ubuntu' or 'rhel'"
  }
}

variable "tantor_instance_type" {
  description = "EC2 instance type for Tantor server (needs RAM for npm build + Ansible)"
  type        = string
  default     = "t3.large"
}

variable "kafka_instance_type" {
  description = "EC2 instance type for Kafka nodes"
  type        = string
  default     = "t3.medium"
}

variable "kafka_node_count" {
  description = "Number of Kafka nodes to provision"
  type        = number
  default     = 3
}

variable "kafka_version" {
  description = "Apache Kafka version to deploy"
  type        = string
  default     = "3.7.0"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "name_prefix" {
  description = "Prefix for all resource names and tags"
  type        = string
  default     = "tantor-e2e"
}

variable "github_repo" {
  description = "Tantor Git repository URL for cloning on EC2"
  type        = string
  default     = "https://github.com/jimmy-fb/tantor.git"
}

variable "github_token" {
  description = "GitHub personal access token (for private repos, leave empty for public)"
  type        = string
  default     = ""
  sensitive   = true
}

# ─── Locals ───

locals {
  ami_id   = var.os_variant == "ubuntu" ? data.aws_ami.ubuntu.id : data.aws_ami.rhel.id
  ssh_user = var.os_variant == "ubuntu" ? "ubuntu" : "ec2-user"
}
