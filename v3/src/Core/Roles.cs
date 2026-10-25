using System;
using System.Collections.Generic;

namespace Wardogs.Core
{
    // The six classes ("roles"), the end-of-match bonus rules, and the read safety limits.
    //
    // The bonus is per role: one tier per 500 XP a role earns in the match, up to 5 tiers (2,500 XP),
    // paid at a fixed XP per tier that depends on placement (seen: 700 for 2nd; 1st/3rd are believed
    // to be 800/600). It lands silently after the match, so the tracker deduces it.
    public static class Roles
    {
        public static readonly string[] Order = { "infantry", "medic", "support", "recon", "driver", "pilot" };

        public static readonly IReadOnlyDictionary<string, string> Names = new Dictionary<string, string>
        {
            ["infantry"] = "Assault", ["medic"] = "Medic", ["support"] = "Support",
            ["recon"] = "Recon", ["driver"] = "Driver", ["pilot"] = "Pilot",
        };

        public const int MatchCap = 2500;
        public const int TierSize = 500;
        public const int TierCount = MatchCap / TierSize;

        public const int MinRoles = 4;        // a read needs at least this many roles; OCR occasionally misses one
        public const long MaxJump = 15000;    // a role can't really gain more than this between two reads
        public const int ConfirmReads = 3;    // identical reads needed before an unusual change is believed

        public static readonly IReadOnlyDictionary<int, string> Placements = new Dictionary<int, string>
        {
            [800] = "1st place", [700] = "2nd place", [600] = "3rd place",   // bonus XP per tier
        };

        public static int Tier(long xp) => (int)Math.Min(TierCount, Math.Floor(xp / (double)TierSize));

        public static string Name(string role) => role != null && Names.TryGetValue(role, out var n) ? n : "?";
    }

    public static class Num
    {
        // PowerShell's [int] cast rounds half to even; the port keeps that so every box and threshold
        // comes out exactly as before.
        public static int R(double v) => (int)Math.Round(v, MidpointRounding.ToEven);
    }
}
