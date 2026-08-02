---
target_repo: dbt-labs/dbt-core
type: bug
status: draft
related: ../plan/02-implementation-steps.md
---

# Fabric's `get_relation` and column introspection pass a `LIKE` pattern to `sp_tables` / `sp_columns`

`crates/dbt-adapter/src/metadata/fabric/mod.rs` and `fabric_get_relation` in
`crates/dbt-adapter/src/metadata/get_relation.rs` interpolate the relation
identifier into `sp_tables` / `sp_columns` as `@table_name`. That parameter is
a `LIKE` pattern by default, so an identifier containing `_` matches more than
itself.

Measured against SQL Server 2022 (16.0.4265.3, Linux) — the same
`adbc_driver_mssql` / go-mssqldb driver Fabric rides. I have no Fabric
warehouse to test against, so the second half below is unverified there.

## Summary

With two tables present, `probe_table` and `probeXtable`:

```
EXEC sys.sp_tables @table_qualifier = 'probe_db',
                   @table_owner = 'probe_schema',
                   @table_name = 'probe_table'
```

returns **two** rows:

```
probe_db | probe_schema | probe_table  | TABLE | NULL
probe_db | probe_schema | probeXtable  | TABLE | NULL
```

`_` is a single-character wildcard in `LIKE`, and `@table_name` is matched with
one unless `@fUsePattern = 0` is passed.

## Consequences

**`fabric_get_relation`** checks for exactly one row:

```rust
if string_array.len() != 1 {
    return Err(AdapterError::new(
        AdapterErrorKind::UnexpectedResult,
        "Did not find 'TABLE_TYPE' for a relation",
    ));
}
```

so a lookup of `stg_orders` fails outright once any `stgXorders` exists in the
same schema. If the extra row sorts first, the caller instead gets the *other*
object's relation type.

**`FabricMetadataAdapter::list_relations_schemas_inner`** builds an Arrow schema
straight from `sp_columns`:

```rust
let sql = format!(
    "EXEC sp_columns @table_qualifier={}, @table_owner={}, @table_name={}",
    ...
);
```

`build_schema_from_sp_columns` then iterates every row, so the second table's
columns are appended to the first's schema, with no error and no duplicate-name
check. Measured: asking for `probe_table` (3 columns) returned 4 rows, the
fourth being `probeXtable.id`.

dbt model names are snake_case by convention, so a schema where one name is a
single-character variant of another is not exotic — `stg_orders` /
`stg-orders`, `fct_sales` / `fctXsales`.

## Fix

`sp_tables` and `sp_columns` both accept `@fUsePattern`:

```
EXEC sys.sp_tables @table_qualifier = 'probe_db',
                   @table_owner = 'probe_schema',
                   @table_name = 'probe_table',
                   @table_type = NULL,
                   @fUsePattern = 0
```

Measured: 1 row. Escaping is not an alternative — `@table_name =
'probe\_table'` returns **zero** rows, because the backslash is not a `LIKE`
escape character in T-SQL without an explicit `ESCAPE` clause, which these
procedures do not expose.

The parameter is documented for both procedures. Whether Fabric's T-SQL surface
accepts it needs checking by someone with a warehouse; if it does not, the
catalog views (`sys.objects`, `sys.columns`) are the alternative.

## Related, but Fabric-specific

The same procedures also read only the connection's current database — any
other `@table_qualifier` is error 15250 on SQL Server. That is not a Fabric bug,
since a warehouse is its own database, but it is why the SQL Server port
(dbt-sqlserver-next/dbt-core#5) uses three-part catalog-view queries rather than
copying this module.

## References

- `sp_tables`:
  https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-tables-transact-sql
- `sp_columns`:
  https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-columns-transact-sql
- Found while porting dbt-sqlserver to v2: dbt-labs/dbt-core#15714
