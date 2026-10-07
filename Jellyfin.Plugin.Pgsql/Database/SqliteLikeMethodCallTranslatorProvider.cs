#pragma warning disable EF1001 // Npgsql's translators live in .Internal namespaces.

using System.Collections.Generic;
using System.Reflection;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Metadata;
using Microsoft.EntityFrameworkCore.Query;
using Microsoft.EntityFrameworkCore.Query.SqlExpressions;
using Npgsql.EntityFrameworkCore.PostgreSQL.Query;
using Npgsql.EntityFrameworkCore.PostgreSQL.Query.ExpressionTranslators.Internal;

namespace Jellyfin.Plugin.Pgsql.Database;

/// <summary>
/// Npgsql's method call translators, with <c>EF.Functions.Like</c> translated to <c>ILIKE</c>.
/// </summary>
/// <remarks>
/// SQLite's <c>LIKE</c> ignores case (for ASCII letters), PostgreSQL's does not. Jellyfin relies on the SQLite
/// behaviour: its search matches the mixed-case OriginalTitle and SortName columns with <c>EF.Functions.Like</c>
/// ("case-insensitive LIKE" in its own comments), so on PostgreSQL searching "amelie" did not find "Amelie". With the
/// "C" collation the plugin uses, <c>ILIKE</c> folds only ASCII letters, like SQLite.
/// </remarks>
public sealed class SqliteLikeMethodCallTranslatorProvider : NpgsqlMethodCallTranslatorProvider
{
    /// <summary>
    /// Initializes a new instance of the <see cref="SqliteLikeMethodCallTranslatorProvider"/> class.
    /// </summary>
    /// <param name="dependencies">The method call translator provider dependencies.</param>
    /// <param name="model">The model.</param>
    /// <param name="contextOptions">The context options.</param>
    public SqliteLikeMethodCallTranslatorProvider(
        RelationalMethodCallTranslatorProviderDependencies dependencies,
        IModel model,
        IDbContextOptions contextOptions)
        : base(dependencies, model, contextOptions)
    {
        // Added translators take precedence over the ones added before, so this one runs before Npgsql's LIKE translator.
        AddTranslators([new CaseInsensitiveLikeTranslator((NpgsqlSqlExpressionFactory)dependencies.SqlExpressionFactory)]);
    }

    private sealed class CaseInsensitiveLikeTranslator : IMethodCallTranslator
    {
        private static readonly MethodInfo _like = typeof(DbFunctionsExtensions).GetRuntimeMethod(
            nameof(DbFunctionsExtensions.Like), [typeof(DbFunctions), typeof(string), typeof(string)])!;

        private static readonly MethodInfo _likeWithEscape = typeof(DbFunctionsExtensions).GetRuntimeMethod(
            nameof(DbFunctionsExtensions.Like), [typeof(DbFunctions), typeof(string), typeof(string), typeof(string)])!;

        private static readonly MethodInfo _iLike = typeof(NpgsqlDbFunctionsExtensions).GetRuntimeMethod(
            nameof(NpgsqlDbFunctionsExtensions.ILike), [typeof(DbFunctions), typeof(string), typeof(string)])!;

        private static readonly MethodInfo _iLikeWithEscape = typeof(NpgsqlDbFunctionsExtensions).GetRuntimeMethod(
            nameof(NpgsqlDbFunctionsExtensions.ILike), [typeof(DbFunctions), typeof(string), typeof(string), typeof(string)])!;

        private readonly NpgsqlLikeTranslator _npgsqlLikeTranslator;

        public CaseInsensitiveLikeTranslator(NpgsqlSqlExpressionFactory sqlExpressionFactory)
        {
            _npgsqlLikeTranslator = new NpgsqlLikeTranslator(sqlExpressionFactory);
        }

        public SqlExpression? Translate(
            SqlExpression? instance,
            MethodInfo method,
            IReadOnlyList<SqlExpression> arguments,
            IDiagnosticsLogger<DbLoggerCategory.Query> logger)
        {
            // Hand the call to Npgsql as EF.Functions.ILike, which keeps its handling of LIKE's escape character.
            if (method.Equals(_like))
            {
                return _npgsqlLikeTranslator.Translate(instance, _iLike, arguments, logger);
            }

            if (method.Equals(_likeWithEscape))
            {
                return _npgsqlLikeTranslator.Translate(instance, _iLikeWithEscape, arguments, logger);
            }

            return null;
        }
    }
}
