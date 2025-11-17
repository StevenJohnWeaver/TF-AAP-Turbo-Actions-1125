terraform {
  required_version = "~> v1.14.0"
  required_providers {
    aap = {
      source = "ansible/aap"
      version = "1.4.0-devpreview1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.21"
    }
    turbonomic = { 
      source  = "IBM/turbonomic" 
      version = "1.2.0"
    }
  }
}

provider "turbonomic" {
  hostname = var.turbo_hostname
  username = var.turbo_username
  password = var.turbo_password
  skipverify = true
}

# Configure the AWS provider
provider "aws" {
  region = "us-east-1"
}

# Configure the AAP provider
provider "aap" {
  host     = var.aap_host
  insecure_skip_verify = true
  username = var.aap_username
  password = var.aap_password
}

# Variable to store the public key for the EC2 instance
variable "ssh_key_name" {
  description = "The name of the key pair for the EC2 instance"
  type        = string
}

# Variable to store the URL for the AAP Event Stream
variable "aap_eventstream_url" {
  description = "The URL of the AAP Event Stream"
  type        = string
}

# Variable to store the AAP details
variable "aap_host" {
  description = "The URL of the Ansible Automation Platform instance"
  type        = string
}

variable "aap_username" {
  description = "The username for the AAP instance"
  type        = string
  sensitive   = true
}

variable "tf-es-username" {
  description = "The username for the AAP instance"
  type        = string
  sensitive   = true
}

variable "tf-es-password" {
  description = "The username for the AAP instance"
  type        = string
  sensitive   = true
}

variable "aap_password" {
  description = "The password for the AAP instance"
  type        = string
  sensitive   = true
}

variable "turbo_username" {
  description = "The username for the Turbonomic instance"
  type        = string
  sensitive   = false
}

variable "turbo_password" {
  description = "The password for the Turbonomic instance"
  type        = string
  sensitive   = true
}

variable "turbo_hostname" {
  description = "The hostname for the Turbonomic instance"
  type        = string
  sensitive   = false
}

data "turbonomic_cloud_entity_recommendation" "example" {
  entity_name  = "EC2VirtualMachine"
  entity_type  = "VirtualMachine"
  default_size = "t3.small"
}

# Provision the AWS EC2 instance(s)
resource "aws_instance" "web_server" {
  ami                       = "ami-0a7d80731ae1b2435" # Ubuntu Server 22.04 LTS (HVM)
  instance_type             = data.turbonomic_cloud_entity_recommendation.example.new_instance_type
  key_name                  = var.ssh_key_name
  vpc_security_group_ids    = [aws_security_group.allow_http_ssh.id]
  associate_public_ip_address = true
  tags = merge(
    {
      Name = "EC2VirtualMachine"
      owner = "sjweaver"
    },
    provider::turbonomic::get_tag()
  )
}

resource "aws_security_group" "allow_http_ssh" {
  name        = "web-server-sg"
#  name_prefix = "allow_http_ssh_"
  description = "Allow SSH, HTTP inbound and all outbound traffic"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Configure AAP resources to run the playbook
# This is the inventory in AAP we are using
data "aap_inventory" "inventory" {
  name        = "Terraform Provisioned Inventory"
  organization_name = "Default"
}

# Create some infrastructure - inventory group - that has an action tied to it
resource "aap_group" "tfaturboaapdemo" {
  name = "tfaturboaapdemo"
  inventory_id = data.aap_inventory.inventory.id
}

# Wait for the EC2 instance to be ready before proceeding
resource "null_resource" "wait_for_instance" {
  # This resource will wait until the EC2 instance is created
  depends_on = [aws_instance.web_server]
  # The provisioner will run a simple shell command that waits for port 22 to be available.
  provisioner "local-exec" {
    command = "until `timeout 1 bash -c 'cat < /dev/null > /dev/tcp/${aws_instance.web_server.public_ip}/22'`; do echo 'Waiting for port 22...'; sleep 5; done"
  }
}

# Add the new EC2 instance to the dynamic inventory
resource "aap_host" "new_host" {
  depends_on      = [null_resource.wait_for_instance]
  inventory_id = data.aap_inventory.inventory.id
  groups = toset([resource.aap_group.tfaturboaapdemo.id])
  name         = aws_instance.web_server.public_ip
  description  = "Host provisioned by Terraform"
  variables    = jsonencode({
    ansible_user = "ubuntu"
    public_ip = aws_instance.web_server.public_ip
    target_hosts = aws_instance.web_server.public_ip
  })
  lifecycle {
    # This action triggers syntax new in terraform
    # It configures terraform to run the listed actions based
    # on the named lifecycle events: "After creating this resource, run the action"
    action_trigger {
      events  = [after_create, after_update]
      actions = [action.aap_eda_eventstream_post.create]
    }
  }
}

# Output the public IP of the new instance
output "web_server_public_ip" {
  value = aws_instance.web_server.public_ip
}

# This is using a new 'aap_eventdispatch' action in the terraform-provider-aap POC
# The purpose is to POST an event with a payload (config) when triggered, and EDA
# is configured with a rulebook to extract these details out of the config and dispatch
# a job

# TF action to run the new AWS provisioning workflow (after ec2 instance are created)
action "aap_eda_eventstream_post" "create" {
  config {
    limit = "tfaturboaapdemo"
    template_type = "job"
    job_template_name = "New AWS nginx Install Debian"
    organization_name = "Default"

    event_stream_config = {
      url = var.aap_eventstream_url
      insecure_skip_verify = true
      username = var.tf-es-username
      password = var.tf-es-password
    }
  }
}
