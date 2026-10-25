using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace Wardogs.Core
{
    // Match XP bookkeeping. No UI in here.
    //
    // Two sources feed a role's XP this match:
    //   - Wardog Level reads (exact totals; the source of truth whenever one comes in), and
    //   - popups (live XP/cash events between reads; reset to the read's total when a read arrives).
    //
    // Thread safety: the worker and the window both use this, so every public member locks Sync.
    // The window locks Sync itself while it reads State/History to draw.
    public sealed class Tracker
    {
        public readonly object Sync = new object();
        public string DataDir { get; }
        public MatchState State { get; private set; }
        public List<HistoryEntry> History { get; private set; } = new();

        readonly Dictionary<string, (long Value, int Count)> pending = new();
        DateTime lastSave = DateTime.MinValue;
        bool saveDue;

        public Tracker(string dataDir)
        {
            DataDir = dataDir;
            Directory.CreateDirectory(Path.Combine(dataDir, "matches"));
            State = new MatchState();
            try { State = (Json.Read<MatchState>(Path.Combine(dataDir, "match.json")) ?? new MatchState()).Fix(); }
            catch (Exception e) { Log.Write("match.json unreadable, starting a new match: " + e.Message); State = new MatchState(); }
            try { History = Json.ReadList<HistoryEntry>(Path.Combine(dataDir, "history.json")).Where(h => h != null).Select(h => h.Fix()).ToList(); }
            catch (Exception e) { Log.Write("history.json unreadable: " + e.Message); History = new(); }
        }

        // ------------------------------------------------------------ saving
        public void Save()
        {
            lock (Sync)
            {
                try
                {
                    Json.Write(Path.Combine(DataDir, "match.json"), State);
                    Json.Write(Path.Combine(DataDir, "history.json"), History);
                    lastSave = DateTime.Now;
                    saveDue = false;
                }
                catch { saveDue = true; }   // file busy (another program has it open): try again shortly
            }
        }

        // Popups can arrive several times a second; write the files at most every few seconds.
        public void SaveSoon()
        {
            lock (Sync) { if ((DateTime.Now - lastSave).TotalSeconds >= 3) Save(); else saveDue = true; }
        }

        public void SaveIfDue() { lock (Sync) { if (saveDue) Save(); } }

        // ------------------------------------------------------------ derived numbers
        // XP earned this match, per role: from Wardog Level reads, plus popups since each role's last read.
        public Dictionary<string, long> RoleGains()
        {
            lock (Sync)
            {
                var gains = new Dictionary<string, long>();
                foreach (var r in Roles.Order)
                {
                    long read = 0;
                    if (State.Base != null && State.Base.TryGetValue(r, out var b) && State.Last.TryGetValue(r, out var l))
                        read = Math.Max(0, l - b);   // never below 0: XP doesn't go down within a match
                    gains[r] = read + State.PopupSinceRead.GetValueOrDefault(r);
                }
                return gains;
            }
        }

        // Wardog level = the six role levels added up. null until every role's level has been read.
        public int? WardogLevel()
        {
            lock (Sync)
            {
                int sum = 0;
                foreach (var r in Roles.Order)
                {
                    if (!State.Levels.TryGetValue(r, out var lv) || lv == null) return null;
                    sum += lv.Value;
                }
                return sum;
            }
        }

        public int LevelsGained()
        {
            lock (Sync)
            {
                int sum = 0;
                foreach (var r in Roles.Order)
                {
                    var now = State.Levels.GetValueOrDefault(r); var start = State.BaseLevels.GetValueOrDefault(r);
                    if (now != null && start != null) sum += Math.Max(0, now.Value - start.Value);
                }
                return sum;
            }
        }

        // The role to feature: the one that last gained XP, else the one with the most this match.
        public string ActiveRole()
        {
            lock (Sync)
            {
                if (!string.IsNullOrEmpty(State.Active)) return State.Active;
                var gains = RoleGains();
                var best = Roles.Order.OrderByDescending(r => gains[r]).First();
                return gains[best] > 0 ? best : null;
            }
        }

        // Tiers reached since they were last announced (not after the match ended: the bonus would trip them).
        List<TierUp> NewTiers()
        {
            var list = new List<TierUp>();
            if (State.EndRequested != null) return list;
            var gains = RoleGains();
            foreach (var r in Roles.Order)
            {
                int tier = Roles.Tier(gains[r]);
                int had = State.Tiers.GetValueOrDefault(r);
                if (tier > had) { list.Add(new TierUp(r, tier)); State.Tiers[r] = tier; }
            }
            return list;
        }

        // True once anything has happened this match (so an empty match isn't filed).
        public bool IsMatchActive() { lock (Sync) return State.Base != null || State.Events.Count > 0; }

        public long MatchCash() { lock (Sync) return MatchCash(State); }

        // The match's net cash: banked cash change (includes gear bought), or the popup sum until the
        // banked cash has been read.
        public static long MatchCash(MatchState s) =>
            s.BankStart != null && s.BankNow != null ? s.BankNow.Value - s.BankStart.Value : s.Cash;

        // ------------------------------------------------------------ Wardog Level reads
        // A role's level from a read; OCR sometimes can't read it (the icon above it confuses it), and then
        // the last known level stands.
        int? ReadLevel(Dictionary<string, RoleProgress> progress, string role) =>
            progress[role].Level ?? State.Levels.GetValueOrDefault(role);

        // Applies one read of the Wardog Level panel. Filed is the history entry when this read finished a match.
        public ReadResult AddRead(Dictionary<string, RoleProgress> progress)
        {
            lock (Sync)
            {
                // Roles whose XP was read this time. Usually all six; a role OCR couldn't read keeps its last value.
                var xp = new Dictionary<string, long>();
                foreach (var r in Roles.Order)
                    if (progress.TryGetValue(r, out var p) && p.Xp != null) xp[r] = p.Xp.Value;
                if (xp.Count < Roles.MinRoles) return new ReadResult { Accepted = false, Note = $"only read {xp.Count} of 6 roles" };

                // Misread protection, per role, so one bad number doesn't block the other roles.
                // - In a match, a role's XP or level can't really drop, and a big drop is always a misread: never taken.
                // - A small drop or a big jump is taken only after ConfirmReads identical reads in a row; that's how a
                //   value is corrected after an earlier misread slipped through.
                var notes = new List<string>(); var corrected = new List<string>();
                foreach (var r in xp.Keys.ToList())
                {
                    if (!State.Last.TryGetValue(r, out var prev)) continue;
                    long delta = xp[r] - prev;
                    bool inMatch = State.Base != null && State.Base.ContainsKey(r);
                    var prevLv = State.Levels.GetValueOrDefault(r);
                    bool levelDrop = prevLv != null && progress[r].Level != null && progress[r].Level < prevLv;
                    if (inMatch && (delta < -Roles.MaxJump || levelDrop))
                    {
                        xp.Remove(r); pending.Remove(r); notes.Add($"{r} rejected ({prev} -> {progress[r].Xp})");
                        continue;
                    }
                    if (delta < 0 || delta > Roles.MaxJump)
                    {
                        pending[r] = pending.TryGetValue(r, out var pd) && pd.Value == xp[r] ? (xp[r], pd.Count + 1) : (xp[r], 1);
                        if (pending[r].Count < Roles.ConfirmReads) { xp.Remove(r); notes.Add($"{r} held ({prev} -> {progress[r].Xp})"); continue; }
                        corrected.Add(r);
                    }
                    pending.Remove(r);
                }
                if (xp.Count == 0) return new ReadResult { Accepted = false, Note = string.Join("; ", notes) };

                // Starting XP is saved per role the first time each role is read this match; popups counted before
                // that read are already in its total, so they're taken back out of the start.
                State.Base ??= new Dictionary<string, long>();
                var fresh = xp.Keys.Where(r => !State.Base.ContainsKey(r)).ToList();
                foreach (var r in fresh)
                {
                    State.Base[r] = xp[r] - State.PopupSinceRead.GetValueOrDefault(r);
                    State.BaseLevels[r] = ReadLevel(progress, r);
                }

                // Whichever role gained the most since the last read is the one being played.
                long bestDelta = 0;
                foreach (var r in xp.Keys)
                {
                    bool hasPrev = State.Last.TryGetValue(r, out var prev);
                    if (!fresh.Contains(r) && !corrected.Contains(r) && hasPrev && xp[r] - prev > bestDelta) { bestDelta = xp[r] - prev; State.Active = r; }
                    State.Last[r] = xp[r];
                    State.Levels[r] = ReadLevel(progress, r);
                    if (progress[r].NextXp != null) State.Next[r] = progress[r].NextXp.Value;
                    State.PopupSinceRead[r] = 0;   // the read is the truth; popups count on from here
                }
                State.LastRead = DateTimeOffset.Now;

                if (State.EndRequested != null)
                    return new ReadResult { Accepted = true, Note = string.Join("; ", notes), Filed = CompleteMatch(false) };
                var tiers = NewTiers();
                Save();
                return new ReadResult { Accepted = true, Note = string.Join("; ", notes), NewTiers = tiers };
            }
        }

        // ------------------------------------------------------------ popups
        public (PopupEvent Event, List<TierUp> NewTiers) AddPopupEvent(string kind, long amount, string reason, string role, bool uncertain)
        {
            lock (Sync)
            {
                var e = new PopupEvent { Id = State.NextEventId, T = DateTimeOffset.Now, Kind = kind, Amount = amount, Reason = reason, Role = role ?? "", Uncertain = uncertain };
                State.NextEventId++;
                State.Events.Add(e);
                AddEventTotals(e, 1);
                if (kind == "xp" && !string.IsNullOrEmpty(role)) State.Active = role;
                var tiers = NewTiers();
                SaveSoon();
                return (e, tiers);
            }
        }

        void AddEventTotals(PopupEvent e, int sign)
        {
            long amt = e.Amount * sign;
            if (e.Kind == "xp")
            {
                if (e.HasRole)
                {
                    State.PopupXp[e.Role] = State.PopupXp.GetValueOrDefault(e.Role) + amt;
                    State.PopupSinceRead[e.Role] = State.PopupSinceRead.GetValueOrDefault(e.Role) + amt;
                }
                else State.UnknownXp += amt;
            }
            else
            {
                State.Cash += amt;
                if (e.Uncertain) State.CashUncertain += sign;
            }
        }

        // A popup's amount was corrected by later readings of the same row.
        public List<TierUp> UpdatePopupEvent(int id, long amount, bool uncertain)
        {
            lock (Sync)
            {
                var e = State.Events.FirstOrDefault(x => x.Id == id);
                if (e == null) return new List<TierUp>();
                AddEventTotals(e, -1);
                e.Amount = amount; e.Uncertain = uncertain;
                AddEventTotals(e, 1);
                var tiers = NewTiers();
                SaveSoon();
                return tiers;
            }
        }

        public void AddUnparsedRead() { lock (Sync) State.Unparsed++; }
        public void AddLiveGap(double seconds) { lock (Sync) State.LiveGapSeconds += seconds; }

        // ------------------------------------------------------------ cash
        // A confirmed read of the cash at the top right. lifeStart is the banked cash when this life began
        // (banked - this life's cash), so gear bought before the first read still counts against the match.
        public bool SetBankRead(long banked, long lifeStart)
        {
            lock (Sync)
            {
                State.BankStart ??= lifeStart;
                if (State.BankNow == banked) return false;
                State.BankNow = banked;
                SaveSoon();
                return true;
            }
        }

        // ------------------------------------------------------------ end of match
        // Marks the match as over. The next Wardog Level read files it with the deduced bonus.
        public bool RequestEndMatch()
        {
            lock (Sync)
            {
                if (State.EndRequested != null) return false;
                State.EndRequested = DateTimeOffset.Now;
                State.EndGains = RoleGains();
                State.EndXp = new Dictionary<string, long>();
                foreach (var r in Roles.Order)
                    if (State.Last.TryGetValue(r, out var l)) State.EndXp[r] = l + State.PopupSinceRead.GetValueOrDefault(r);
                Save();
                return true;
            }
        }

        // Files the match into history with its breakdown and starts the next one.
        // The bonus per role = XP after the match (this read) - XP when it ended (last read + popups since).
        public HistoryEntry CompleteMatch(bool noFinalRead)
        {
            lock (Sync)
            {
                var s = State;
                var gains = s.EndGains ?? RoleGains();
                var roles = new Dictionary<string, long>(); var bonus = new Dictionary<string, long>(); var popup = new Dictionary<string, long>();
                foreach (var r in Roles.Order)
                {
                    long g = gains.GetValueOrDefault(r);
                    if (g > 0) roles[r] = g;
                    if (s.PopupXp.GetValueOrDefault(r) != 0) popup[r] = s.PopupXp[r];
                    if (!noFinalRead && s.EndXp != null && s.EndXp.TryGetValue(r, out var end) && s.Last.TryGetValue(r, out var last))
                        bonus[r] = last - end;
                }
                long? bonusTotal = bonus.Count > 0 ? bonus.Values.Sum() : null;

                // Placement: the bonus is a fixed XP per tier, so total bonus / total tiers gives the payout.
                int? payout = null; string placement = null; bool? consistent = null;
                int tiers = bonus.Keys.Sum(r => Roles.Tier(gains.GetValueOrDefault(r)));
                if (tiers > 0 && bonusTotal != null)
                {
                    payout = (int)(Math.Round(bonusTotal.Value / (double)tiers / 100.0, MidpointRounding.ToEven) * 100);
                    consistent = true;
                    foreach (var r in bonus.Keys)
                        if (Math.Abs(bonus[r] - Roles.Tier(gains.GetValueOrDefault(r)) * (long)payout.Value) > 50) consistent = false;
                    placement = Roles.Placements.TryGetValue(payout.Value, out var pl) ? pl : null;
                }

                var warnings = new List<string>();
                if (noFinalRead) warnings.Add("There was no Wardog Level read after the match, so the end-of-match bonus couldn't be deduced.");
                if (s.Unparsed > 0) warnings.Add($"{s.Unparsed} popup reads couldn't be understood. A missed popup would show up as extra bonus.");
                if (s.LiveGapSeconds >= 30) warnings.Add($"Popup tracking was off or the game wasn't detected for about {Math.Max(1, Num.R(s.LiveGapSeconds / 60))} min of this match.");
                if (s.UnknownXp > 0) warnings.Add($"{s.UnknownXp} popup XP couldn't be matched to a class.");
                if (s.CashUncertain > 0) warnings.Add($"{s.CashUncertain} cash amounts were uncertain (the $ sign was misread).");
                if (consistent == false) warnings.Add($"The deduced bonus isn't a clean multiple of {payout} XP per tier for every class, so something was probably missed.");
                foreach (var r in bonus.Keys) if (bonus[r] < 0) warnings.Add($"{Roles.Name(r)}'s deduced bonus is negative, so a popup was likely miscounted.");

                var stamp = s.Start.LocalDateTime.ToString("yyyyMMdd-HHmmss");
                var eventsFile = $"matches\\{stamp}.json";
                try { Json.Write(Path.Combine(DataDir, eventsFile), s.Events); } catch (Exception e) { Log.Write("events save ERROR " + e.Message); }

                long total = roles.Values.Sum() + (bonusTotal ?? 0);
                var entry = new HistoryEntry
                {
                    Start = s.Start, End = s.EndRequested ?? DateTimeOffset.Now,
                    Xp = total, Roles = roles, PopupXp = popup, Bonus = bonus, BonusTotal = bonusTotal,
                    Payout = payout, Placement = placement, Cash = s.Cash, ResultsCash = s.ResultsCash,
                    NetCash = s.BankStart != null && s.BankNow != null ? MatchCash(s) : null,
                    EventCount = s.Events.Count, Unparsed = s.Unparsed, Warnings = warnings, EventsFile = eventsFile,
                    Snapshot = null,
                };
                if (total > 0 || s.Events.Count > 0) History = new[] { entry }.Concat(History).Take(100).ToList();

                // Next match starts from here. After a final read that XP already includes the bonus.
                State = new MatchState
                {
                    Last = s.Last, Levels = s.Levels, Next = s.Next, LastRead = s.LastRead,
                };
                if (!noFinalRead && s.Last.Count > 0)
                {
                    State.Base = new Dictionary<string, long>(s.Last);
                    State.BaseLevels = new Dictionary<string, int?>(s.Levels);
                }
                pending.Clear();
                Save();
                return entry;
            }
        }

        public void SetSnapshot(HistoryEntry entry, string relPath) { lock (Sync) { entry.Snapshot = relPath; SaveSoon(); } }

        // Loads a filed match's full event list.
        public List<PopupEvent> LoadEvents(HistoryEntry entry)
        {
            if (string.IsNullOrEmpty(entry?.EventsFile)) return new List<PopupEvent>();
            try { return Json.ReadList<PopupEvent>(Path.Combine(DataDir, entry.EventsFile)); }
            catch (Exception e) { Log.Write("events load ERROR " + e.Message); return new List<PopupEvent>(); }
        }
    }
}
