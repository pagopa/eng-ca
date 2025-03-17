default_max_request_duration = "90s"
ui                           = true

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"
}

# Uncomment if vault data migration is needed
seal "shamir" {}

# https://www.vaultproject.io/docs/configuration/seal/awskms
#seal "awskms" {
#}

storage "dynamodb" {
  ha_enabled = "true"
  region     = "eu-west-1"
  table      = "vault-data"
}