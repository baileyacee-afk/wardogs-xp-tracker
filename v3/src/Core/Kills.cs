using System;
using System.Collections.Generic;
using System.Linq;

namespace Wardogs.Core
{
    // Kills and kill assists, counted from the popups.
    //
    // Each kill pays twice: a cash row ("KILL +$2,750") and, a second or few later, an XP row ("KILL 250XP").
    // Either one can be misread and missed, so a cash row and the XP row that follows it count as one kill,
    // and a row of either kind with no partner still counts. Headshot, shutdown, revenge and artillery kills
    // replace the plain "KILL" rows; team kills don't count.
    public static class Kills
    {
        static readonly HashSet<string> KillReasons = new(StringComparer.OrdinalIgnoreCase)
            { "KILL", "HEADSHOT KILL", "SHUTDOWN KILL", "REVENGE KILL", "ARTILLERY KILL" };
        static readonly HashSet<string> AssistReasons = new(StringComparer.OrdinalIgnoreCase) { "KILL ASSIST" };

        // How far apart a kill's cash row and XP row can be (the cash row comes first, up to ~6 s seen).
        const double CashBefore = 7, CashAfter = 2;

        public static (int Kills, int Assists) Count(IEnumerable<PopupEvent> events)
        {
            var list = events?.ToList() ?? new List<PopupEvent>();
            return (CountOf(list, KillReasons), CountOf(list, AssistReasons));
        }

        static int CountOf(List<PopupEvent> events, HashSet<string> reasons)
        {
            var mine = events.Where(e => e.Reason != null && reasons.Contains(e.Reason) && (e.Kind != "cash" || e.Amount > 0)).OrderBy(e => e.T).ToList();
            var cash = mine.Where(e => e.Kind == "cash").ToList();
            var paired = new HashSet<PopupEvent>();
            int n = 0;
            foreach (var x in mine.Where(e => e.Kind == "xp"))
            {
                n++;
                var c = cash.FirstOrDefault(c => !paired.Contains(c) && (x.T - c.T).TotalSeconds <= CashBefore && (c.T - x.T).TotalSeconds <= CashAfter);
                if (c != null) paired.Add(c);
            }
            return n + cash.Count(c => !paired.Contains(c));
        }
    }
}
