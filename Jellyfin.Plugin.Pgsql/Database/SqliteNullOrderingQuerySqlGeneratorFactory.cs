#pragma warning disable EF1001 // Npgsql's query SQL generator lives in an .Internal namespace.

using Microsoft.EntityFrameworkCore.Query;
using Microsoft.EntityFrameworkCore.Storage;
using Npgsql.EntityFrameworkCore.PostgreSQL.Infrastructure.Internal;
using Npgsql.EntityFrameworkCore.PostgreSQL.Query.Internal;

namespace Jellyfin.Plugin.Pgsql.Database;

/// <summary>
/// Creates Npgsql query SQL generators that order NULLs the way SQLite does: first in ascending and last in
/// descending orderings (PostgreSQL does the opposite). Jellyfin's sort orders, e.g. for resume and next-up lists,
/// were written against SQLite. This uses Npgsql's own "reverse null ordering" support, whose public option
/// became internal in Npgsql 10.
/// </summary>
public sealed class SqliteNullOrderingQuerySqlGeneratorFactory : IQuerySqlGeneratorFactory
{
    private readonly QuerySqlGeneratorDependencies _dependencies;
    private readonly IRelationalTypeMappingSource _typeMappingSource;
    private readonly INpgsqlSingletonOptions _npgsqlSingletonOptions;

    /// <summary>
    /// Initializes a new instance of the <see cref="SqliteNullOrderingQuerySqlGeneratorFactory"/> class.
    /// </summary>
    /// <param name="dependencies">The query SQL generator dependencies.</param>
    /// <param name="typeMappingSource">The relational type mapping source.</param>
    /// <param name="npgsqlSingletonOptions">The Npgsql singleton options.</param>
    public SqliteNullOrderingQuerySqlGeneratorFactory(
        QuerySqlGeneratorDependencies dependencies,
        IRelationalTypeMappingSource typeMappingSource,
        INpgsqlSingletonOptions npgsqlSingletonOptions)
    {
        _dependencies = dependencies;
        _typeMappingSource = typeMappingSource;
        _npgsqlSingletonOptions = npgsqlSingletonOptions;
    }

    /// <inheritdoc/>
    public QuerySqlGenerator Create()
        => new NpgsqlQuerySqlGenerator(
            _dependencies,
            _typeMappingSource,
            reverseNullOrderingEnabled: true,
            _npgsqlSingletonOptions.PostgresVersion);
}
