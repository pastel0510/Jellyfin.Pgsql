using Jellyfin.Database.Implementations;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Jellyfin.Plugin.Pgsql.Migrations
{
    /// <summary>
    /// Data-only migration: sets NaN and infinite values of nullable real/double precision columns to NULL.
    /// SQLite stores NaN as NULL, PostgreSQL keeps it, and there it sorts above every number and passes range filters
    /// (a NaN community rating counts as "at least 7"). Jellyfin 12.3 stops writing non-finite ratings and gains but
    /// does not clean the stored ones; this makes PostgreSQL hold what SQLite would. No schema change, so the model
    /// snapshot is unchanged.
    /// </summary>
    [DbContext(typeof(JellyfinDbContext))]
    [Migration("20261023120000_Jellyfin12.3_NonFiniteFloats")]
    public partial class Jellyfin123NonFiniteFloats : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql(
                """
                DO $$
                DECLARE
                    r record;
                BEGIN
                    FOR r IN
                        SELECT c.table_name, c.column_name
                        FROM information_schema.columns c
                        JOIN information_schema.tables t
                            ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE'
                        WHERE c.table_schema = 'public'
                            AND c.data_type IN ('real', 'double precision')
                            AND c.is_nullable = 'YES'
                    LOOP
                        EXECUTE format(
                            'UPDATE %I SET %I = NULL WHERE %I IN (''NaN'', ''Infinity'', ''-Infinity'')',
                            r.table_name, r.column_name, r.column_name);
                    END LOOP;
                END $$;
                """);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            // The values were not numbers; there is nothing to go back to.
        }
    }
}
