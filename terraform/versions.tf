terraform {
  # Terraform requires literal constraints in this block; variables and locals
  # cannot be interpolated here. Pin both versions immediately before execution.
  # TODO(pin-at-execution): replace the placeholder and uncomment:
  # required_version = "TODO(pin-at-execution)"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # TODO(pin-at-execution): replace the placeholder and uncomment:
      # version = "TODO(pin-at-execution)"
    }
  }
}
