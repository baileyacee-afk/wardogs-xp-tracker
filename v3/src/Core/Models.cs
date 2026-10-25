using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Wardogs.Core
{
    // One XP or cash popup.
    public sealed class PopupEvent
    {
        public int Id { get; set; }
        public DateTimeOffset T { get; set; }
        public string Kind { get; set; }        // "xp" or "cash"
        public long Amount { get; set; }
        public string Reason { get; set; }
        public string Role { get; set; }        // the class an XP popup went to; null/"" when unknown or cash
        public bool Uncertain { get; set; }     // cash whose "$" was misread

        [JsonIgnore] public bool HasRole => !string.IsNullOrEmpty(Role);
    }

    // The match in progress (match.json). Field names and meanings match the PowerShell version.
    public sealed class MatchState
    {
        public DateTimeOffset Start { get; set; } = DateTimeOffset.Now;
        public Dictionary<string, long> Base { get; set; }                         // XP per role when the match started
        public Dictionary<string, long> Last { get; set; } = new();               // latest accepted Wardog Level XP per role
        public Dictionary<string, int?> Levels { get; set; } = new();
        public Dictionary<string, int?> BaseLevels { get; set; } = new();          // level per role when the match started
        public Dictionary<string, long> Next { get; set; } = new();               // XP needed for the next level
        public Dictionary<string, int> Tiers { get; set; } = new();               // highest bonus tier already announced
        public string Active { get; set; }                                         // the role that most recently gained XP
        public DateTimeOffset? LastRead { get; set; }
        // popups
        [JsonConverter(typeof(FlexListConverter<PopupEvent>))]
        public List<PopupEvent> Events { get; set; } = new();
        public int NextEventId { get; set; } = 1;
        public Dictionary<string, long> PopupXp { get; set; } = new();            // popup XP per role over the whole match
        public Dictionary<string, long> PopupSinceRead { get; set; } = new();     // since that role's last Wardog Level read
        public long UnknownXp { get; set; }                                        // popup XP whose class couldn't be told
        public long Cash { get; set; }                                             // sum of cash popups (not gear bought)
        public long? BankStart { get; set; }                                       // banked cash when the first life read began
        public long? BankNow { get; set; }                                         // latest banked cash read
        public int CashUncertain { get; set; }
        public int Unparsed { get; set; }
        public double LiveGapSeconds { get; set; }                                 // time with live tracking off / game not found
        // end of match
        public DateTimeOffset? EndRequested { get; set; }
        public Dictionary<string, long> EndXp { get; set; }                       // estimated XP per role when the match ended
        public Dictionary<string, long> EndGains { get; set; }                    // match XP per role then (before the bonus)
        public long? ResultsCash { get; set; }

        // Files can hold null where a collection is expected.
        public MatchState Fix()
        {
            Last ??= new(); Levels ??= new(); BaseLevels ??= new(); Next ??= new(); Tiers ??= new();
            Events ??= new(); PopupXp ??= new(); PopupSinceRead ??= new();
            if (NextEventId < 1) NextEventId = 1;
            return this;
        }
    }

    // One filed match (history.json). Matches from v1.x only have Start, End, Xp and Roles.
    public sealed class HistoryEntry
    {
        public DateTimeOffset Start { get; set; }
        public DateTimeOffset? End { get; set; }
        public long Xp { get; set; }
        public Dictionary<string, long> Roles { get; set; } = new();
        public Dictionary<string, long> PopupXp { get; set; } = new();
        public Dictionary<string, long> Bonus { get; set; } = new();
        public long? BonusTotal { get; set; }
        public int? Payout { get; set; }
        public string Placement { get; set; }
        public long Cash { get; set; }
        public long? ResultsCash { get; set; }
        public long? NetCash { get; set; }
        public int EventCount { get; set; }
        public int Unparsed { get; set; }
        [JsonConverter(typeof(FlexListConverter<string>))]
        public List<string> Warnings { get; set; } = new();
        public string EventsFile { get; set; }
        public string Snapshot { get; set; }   // picture of the tracker once filed

        public HistoryEntry Fix()
        {
            Roles ??= new(); PopupXp ??= new(); Bonus ??= new(); Warnings ??= new();
            return this;
        }
    }

    // settings.json
    public sealed class Settings
    {
        public int Opacity { get; set; } = 100;
        public bool ClickThrough { get; set; }
        public string PanelRect { get; set; }       // "x,y,w,h": where the in-game Wardog Level panel was last found
        public int PanelRoles { get; set; }         // how many roles were readable when it was found
        public bool Continuous { get; set; } = true;   // live popup tracking on
        public int PopupPollMs { get; set; } = 300; // how often the popup area is checked
        public string PopupRect { get; set; }       // "x,y,w,h": where popups appear; default is under the cash boxes
        public string WindowPos { get; set; }       // "x,y": where you last dragged the window
        public bool StartMenuShortcut { get; set; } = true;
        public bool DesktopShortcut { get; set; }
        public bool StartWithWindows { get; set; }
    }

    // One role read off the Wardog Level panel. Level can be missing (OCR garbles it under some icons).
    public sealed class RoleProgress
    {
        public int? Level { get; set; }
        public long? Xp { get; set; }
        public long? NextXp { get; set; }
    }

    public readonly record struct TierUp(string Role, int Tier);

    public sealed class ReadResult
    {
        public bool Accepted;
        public string Note = "";
        public List<TierUp> NewTiers = new();
        public HistoryEntry Filed;
    }
}
