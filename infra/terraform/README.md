# Demo infrastructure (optional)

Terraform that creates API Management instances to try the pipelines against. Skip this folder if you already have instances.

The layout follows Microsoft's Terraform quickstart for API Management ([`Azure/terraform` › `quickstart/101-azure-api-management-create`](https://github.com/Azure/terraform/tree/master/quickstart/101-azure-api-management-create)): `providers.tf`, `main.tf`, `variables.tf` and `outputs.tf`.

## What it creates

For each environment in `environments` (default `development` and `production`, in `westus`):

| Resource | Name | Purpose |
|---|---|---|
| Resource group | `rg-apiops-<environment>-<region>` | Holds that environment's resources |
| API Management | `apim-apiops-<environment>-<random>` | The instance the pipelines extract from or publish to |
| User-assigned managed identity | `id-apiops-<environment>` | The identity the `apiops-<environment>` service connection signs in as |
| Role assignment | API Management Service Contributor | Scoped to that environment's instance only |
| Role assignment | Reader | On that environment's resource group. `apiops publish` reads it in a pre-flight check. |
| Federated credential (second pass) | `azure-devops-<environment>` | Lets the service connection sign in without a client secret |

With `demo_key_vault = true` (the default), each environment also gets:

| Resource | Name | Purpose |
|---|---|---|
| System-assigned identity on the APIM instance | — | API Management reads Key Vault-backed named values with it |
| Key Vault (RBAC) | `kv-apiops-<env>-<random>` | Holds that environment's secrets |
| Secret | `petstore-api-key` | Demo value for a Key Vault-backed named value |
| Role assignment | Key Vault Secrets User | APIM's identity, on its own environment's vault only |
| Role assignment | Key Vault Secrets Officer | Whoever runs Terraform, to write the demo secret |

The output `key_vault_secret_uris` gives each secret's versionless URI. Add it to the environment's variable group as `NV_PETSTORE_API_KEY_KV_URL`, so the publisher configuration can point the named value at that environment's own vault.

If you turn the demo on for instances that already exist, apply in two steps. The provider can't plan the role assignment for an identity that is added in the same run:

```bash
terraform apply -target=azurerm_api_management.apim
terraform apply
```

Terraform creates the instances only. APIs, products and policies inside them are managed by the APIOps pipelines. Don't manage the same resources with both tools.

## Before you start

- Terraform 1.5 or later and the Azure CLI.
- **Owner**, or **Contributor** plus **User Access Administrator**, on the subscription. Creating role assignments needs the second role.
- Time and cost: the default **Developer** tier takes 30–45 minutes per instance, costs roughly USD 50 per month per instance, and has no SLA. Use it for demos and testing only. Set `sku_name = "BasicV2"` for instances that are ready in minutes.

## 1. Create the instances

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # then set subscription_id and publisher_email
az login
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

## 2. Create the variable groups

```bash
terraform output variable_groups
```

Create one variable group per entry in **Pipelines → Library**, using the entry's name (for example `apiops-westus-development`) and its three variables.

## 3. Create the service connections

```bash
terraform output service_connections
```

For each entry, in **Project settings → Service connections → New → Azure Resource Manager**:

1. Identity type: **App registration or managed identity (manual)**. Credential: **Workload identity federation**.
2. Name it as the entry's key (for example `apiops-development`).
3. Azure DevOps shows an **Issuer** and a **Subject identifier**. Copy both into `federated_credentials` in `terraform.tfvars`, under that environment.
4. Enter the entry's subscription, client ID and tenant ID. Scope it to the entry's resource group.

When every environment is in `federated_credentials`, run `terraform apply` again. It adds the federated credentials. Then go back to each service connection and choose **Verify and save**.

## 4. Continue with the main README

Carry on from [step 3 of the quick start](../../README.md#3-create-the-environments-and-their-checks) (environments and their checks).

## Clean up

```bash
terraform destroy
```

Deleted instances are purged straight away (see `providers.tf`), so the names can be reused. Delete the variable groups and service connections in Azure DevOps yourself.

## Notes

- **State**: kept locally in `terraform.tfstate`, which `.gitignore` excludes. It contains resource IDs from your subscription, so don't commit it. For shared use, configure a remote backend.
- **Provider version**: `azurerm ~> 4.0`, matching Microsoft's quickstart. Version 5.x is available. Check its upgrade guide before raising the constraint.
- **Other regions**: set `location` to `eastus` or `westeurope` to match the pipelines' other Region options. Run one copy per region, each with its own state (for example with Terraform workspaces).
