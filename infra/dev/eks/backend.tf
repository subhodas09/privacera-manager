terraform {
  backend "s3" {
    key          = "privacera/dev/eks/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
