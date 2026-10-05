using Jellyfin.Database.Implementations;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Jellyfin.Plugin.Pgsql.Migrations
{
    /// <summary>
    /// Data-only migration: converts stored -infinity/infinity timestamps and dates to 0001-01-01/9999-12-31.
    /// Npgsql used to map DateTime.MinValue/MaxValue to infinity; the provider now turns that mapping off
    /// (Npgsql.DisableDateTimeInfinityConversions), after which Npgsql can no longer read stored infinity values.
    /// No schema change, so the model snapshot is unchanged.
    /// </summary>
    [DbContext(typeof(JellyfinDbContext))]
    [Migration("20261005130000_Jellyfin12.1_DateTimeInfinity")]
    public partial class Jellyfin121DateTimeInfinity : Migration
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
                        SELECT c.table_name, c.column_name, c.data_type
                        FROM information_schema.columns c
                        JOIN information_schema.tables t
                          ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE'
                        WHERE c.table_schema = current_schema()
                          AND c.data_type IN ('timestamp with time zone', 'timestamp without time zone', 'date')
                    LOOP
                        EXECUTE format(
                            'UPDATE %I SET %I = CASE WHEN %I = ''-infinity'' THEN %L::%s ELSE %L::%s END WHERE %I IN (''-infinity'', ''infinity'')',
                            r.table_name, r.column_name, r.column_name,
                            '0001-01-01 00:00:00+00', r.data_type,
                            '9999-12-31 23:59:59.999999+00', r.data_type,
                            r.column_name);
                    END LOOP;
                END $$;
                """);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            // One-way: the original infinity values are not restored.
        }
    }
}
