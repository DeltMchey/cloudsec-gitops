terraform {
  # Literal constraints pinned at execution 2026-11-25; the CI gate
  # (terraform.yml) installs the same CLI version so local and gate runs are
  # identical.
  required_version = "1.17.2"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.74.0"
    }
  }
}
