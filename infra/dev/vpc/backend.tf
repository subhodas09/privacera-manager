terraform {
  backend "s3" {
    key          = "privacera/dev/vpc/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
