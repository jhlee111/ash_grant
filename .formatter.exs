# Used by "mix format"
spark_locals_without_parens = [
  actions: 1,
  can_perform: 1,
  can_perform: 2,
  can_perform_actions: 1,
  default_field_policies: 1,
  default_policies: 1,
  description: 1,
  except: 1,
  field_group: 2,
  field_group: 3,
  field_group_permissions: 1,
  for_actions: 1,
  from_path: 1,
  inherits: 1,
  instance_key: 1,
  mask: 1,
  mask_with: 1,
  name: 1,
  owner_field: 1,
  public?: 1,
  resolve_argument: 1,
  resolve_argument: 2,
  resolver: 1,
  resource: 1,
  resource_name: 1,
  scope: 2,
  scope: 3,
  scope: 4,
  scope_resolver: 1,
  scope_through: 1,
  scope_through: 2,
  write: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
