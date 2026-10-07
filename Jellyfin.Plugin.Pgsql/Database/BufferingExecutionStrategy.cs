using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;

namespace Jellyfin.Plugin.Pgsql.Database;

/// <summary>
/// An execution strategy that never retries but makes EF Core buffer query results.
/// </summary>
/// <remarks>
/// SQLite allows a command while a data reader is still open on the same connection; Npgsql does not (there is no
/// MARS in PostgreSQL) and throws <c>NpgsqlOperationInProgressException</c>. Jellyfin relies on the SQLite behaviour,
/// e.g. the 12.2 MigrateRatingLevels routine runs <c>ExecuteUpdate</c> inside a <c>foreach</c> over a query. EF Core
/// reads the whole result before handing out the first row when the execution strategy reports that it retries, so
/// this strategy reports that without retrying. Unlike <see cref="ExecutionStrategy"/> it does not reject user
/// transactions, which Jellyfin opens with <c>BeginTransaction</c>.
/// </remarks>
public sealed class BufferingExecutionStrategy : IExecutionStrategy
{
    private readonly ExecutionStrategyDependencies _dependencies;

    /// <summary>
    /// Initializes a new instance of the <see cref="BufferingExecutionStrategy"/> class.
    /// </summary>
    /// <param name="dependencies">The execution strategy dependencies.</param>
    public BufferingExecutionStrategy(ExecutionStrategyDependencies dependencies)
    {
        _dependencies = dependencies;
    }

    /// <inheritdoc/>
    public bool RetriesOnFailure => true;

    /// <inheritdoc/>
    public TResult Execute<TState, TResult>(
        TState state,
        Func<DbContext, TState, TResult> operation,
        Func<DbContext, TState, ExecutionResult<TResult>>? verifySucceeded)
        => operation(_dependencies.CurrentContext.Context, state);

    /// <inheritdoc/>
    public Task<TResult> ExecuteAsync<TState, TResult>(
        TState state,
        Func<DbContext, TState, CancellationToken, Task<TResult>> operation,
        Func<DbContext, TState, CancellationToken, Task<ExecutionResult<TResult>>>? verifySucceeded,
        CancellationToken cancellationToken = default)
        => operation(_dependencies.CurrentContext.Context, state, cancellationToken);
}
