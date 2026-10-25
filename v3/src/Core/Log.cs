using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;

namespace Wardogs.Core
{
    // tracker.log in the data folder. Logging must never stop the tracker (e.g. if the log is open
    // in another program), so every write swallows errors.
    public static class Log
    {
        static readonly object sync = new object();
        static string path;

        public static void Start(string file, string version)
        {
            path = file;
            try { File.WriteAllText(path, $"{DateTime.Now:s} starting v{version}\r\n", new UTF8Encoding(false)); } catch { }
        }

        public static void Write(string text)
        {
            if (path == null) return;
            lock (sync) { try { File.AppendAllText(path, $"{DateTime.Now:s} {text}\r\n"); } catch { } }
        }
    }

    // Time spent per kind of work, written to the log once a minute (for keeping CPU use low).
    public static class Perf
    {
        static readonly object sync = new object();
        static Dictionary<string, (int N, double Ms)> parts = new();
        static DateTime since = DateTime.Now;

        public static void Add(string name, Stopwatch sw)
        {
            lock (sync) { var p = parts.GetValueOrDefault(name); parts[name] = (p.N + 1, p.Ms + sw.Elapsed.TotalMilliseconds); }
        }

        public static void WriteIfDue()
        {
            lock (sync)
            {
                double secs = (DateTime.Now - since).TotalSeconds;
                if (secs < 60) return;
                var text = string.Join("; ", parts.OrderBy(k => k.Key).Select(k => $"{k.Key} {k.Value.N}x {k.Value.Ms:N0}ms"));
                double total = parts.Values.Sum(v => v.Ms);
                double cpu = Process.GetCurrentProcess().TotalProcessorTime.TotalMilliseconds;
                double cpuPct = (cpu - lastCpu) / 1000 / secs * 100;
                Log.Write($"perf (last {secs:N0}s, work {100 * total / 1000 / secs:N1}% of a core, process {cpuPct:N1}% of a core): {text}");
                lastCpu = cpu;
                parts = new(); since = DateTime.Now;
            }
        }

        static double lastCpu = Process.GetCurrentProcess().TotalProcessorTime.TotalMilliseconds;
    }
}
