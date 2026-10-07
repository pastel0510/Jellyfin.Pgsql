using Jellyfin.Database.Implementations;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Jellyfin.Plugin.Pgsql.Migrations
{
    /// <summary>
    /// Data-only migration: harmonizes conflicting user data rows before Jellyfin 12.2's HarmonizeConflictingUserData
    /// routine does. EF migrations run before Jellyfin's application migration routines, so the routine then finds no
    /// conflicts. It picks the same winner (most recent play, then play count, then position) but breaks the remaining
    /// ties on Played and IsFavorite, which the routine leaves to the order the rows come back in: it could copy an
    /// unplayed row over played ones and mark a watched item unwatched. On a database the routine already ran on there
    /// are no conflicts left, so this changes nothing. No schema change, so the model snapshot is unchanged.
    /// </summary>
    [DbContext(typeof(JellyfinDbContext))]
    [Migration("20261007120000_Jellyfin12.2_HarmonizeUserData")]
    public partial class Jellyfin122HarmonizeUserData : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            // The conflict test mirrors the routine's; the placeholder item holds detached user data and is skipped.
            migrationBuilder.Sql(
                """
                WITH conflicts AS (
                    SELECT "ItemId", "UserId"
                    FROM "UserData"
                    WHERE "ItemId" <> '00000000-0000-0000-0000-000000000001'
                    GROUP BY "ItemId", "UserId"
                    HAVING count(*) > 1
                        AND (min("PlaybackPositionTicks") <> max("PlaybackPositionTicks")
                            OR min("PlayCount") <> max("PlayCount")
                            OR bool_or("Played") <> bool_and("Played")
                            OR bool_or("IsFavorite") <> bool_and("IsFavorite")
                            OR min("LastPlayedDate") <> max("LastPlayedDate"))
                ),
                winners AS (
                    SELECT DISTINCT ON (u."ItemId", u."UserId") u.*
                    FROM "UserData" u
                    JOIN conflicts c ON c."ItemId" = u."ItemId" AND c."UserId" = u."UserId"
                    ORDER BY u."ItemId", u."UserId",
                        u."LastPlayedDate" DESC NULLS LAST,
                        u."PlayCount" DESC,
                        u."PlaybackPositionTicks" DESC,
                        u."Played" DESC,
                        u."IsFavorite" DESC,
                        u."CustomDataKey"
                )
                UPDATE "UserData" t
                SET "AudioStreamIndex" = w."AudioStreamIndex",
                    "IsFavorite" = w."IsFavorite",
                    "LastPlayedDate" = w."LastPlayedDate",
                    "Likes" = w."Likes",
                    "PlaybackPositionTicks" = w."PlaybackPositionTicks",
                    "PlayCount" = w."PlayCount",
                    "Played" = w."Played",
                    "Rating" = w."Rating",
                    "SubtitleStreamIndex" = w."SubtitleStreamIndex"
                FROM winners w
                WHERE t."ItemId" = w."ItemId"
                    AND t."UserId" = w."UserId"
                    AND t."CustomDataKey" <> w."CustomDataKey";
                """);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            // The rows held conflicting values; there is nothing to go back to.
        }
    }
}
