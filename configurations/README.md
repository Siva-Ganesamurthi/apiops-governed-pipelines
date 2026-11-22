# Configurations

Each target (region + environment) can have up to two optional files:

```
configurations/
└── <region>/
    └── <environment>/
        ├── configuration.extractor.yaml   # what to extract from this instance (apiops extract --filter)
        └── configuration.publisher.yaml   # overrides when publishing to this instance (apiops publish --overrides)
```

Folder names are lowercase, for example `configurations/westus/production/configuration.publisher.yaml`.

Neither file is required. Without an extractor configuration, everything is extracted. Without a publisher configuration, artifacts are published as they are.

Copy the examples in [`_examples/`](_examples/) to get started. Both files use the [APIOps CLI](https://github.com/Azure/apiops-cli/tree/main/docs) formats, which keep the key names of the APIOps toolkit v7 (`apis`, `backends`, `namedValues`, `products` and so on).

## Extractor configuration

For each resource type:

| You write | The extractor |
|---|---|
| nothing (key left out) | extracts every resource of that type |
| a list of names | extracts only those |
| `[]` | extracts none |

Names can use `*` and `?` wildcards, and `'!name'` excludes a match (keep the quotes, or YAML reads `!` as a tag). Matching ignores case. Resources that a selected resource depends on, such as the named values and backends an API's policy uses, are extracted too.

## Publisher configuration

The publisher matches each override to an artifact by `name` and applies its `properties`. Values that differ per environment are written as `{#VARIABLE_NAME#}` placeholders (the CLI documentation's `{#[VARIABLE_NAME]#}` form works too). The pipeline fills them from the target's variable group just before publishing, because the CLI doesn't replace placeholders itself.

Rules for placeholders:

1. Put every placeholder inside double quotes: `value: "{#NV_ORDERS_URL#}"`.
2. Every placeholder needs a variable with that name in the target's variable group. If one is missing, the run **fails** before anything is published.
3. Keep secrets in Key Vault and reference them (`keyVault.secretIdentifier`). If you must use a secret pipeline variable, map it in the `env:` block of the "Resolve publisher configuration" step in `pipelines/templates/steps-publish.yaml`.
4. Placeholders on comment lines are ignored.
5. Don't set `apimServiceName` in this file. The CLI ignores it; the target instance comes from the variable group.

### Secret named values

The extractor never writes secret values to the repository: it writes `*** REDACTED ***` instead. Give every secret named value a Key Vault reference (or a placeholder value) in each target's publisher configuration, otherwise the CLI won't publish it.
