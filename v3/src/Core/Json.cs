using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Wardogs.Core
{
    // Reads and writes the same JSON files the PowerShell version used (match.json, history.json,
    // settings.json, symbols.json, matches\*.json), so switching versions loses nothing.
    // PowerShell's JSON has quirks this tolerates: a UTF-8 BOM, a list of one item sometimes
    // written as a bare object, numbers written as strings, and null for empty collections.
    public static class Json
    {
        public static readonly JsonSerializerOptions Options = new JsonSerializerOptions
        {
            WriteIndented = true,
            PropertyNameCaseInsensitive = true,
            NumberHandling = JsonNumberHandling.AllowReadingFromString,
            ReadCommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true,
        };

        static readonly Encoding Utf8 = new UTF8Encoding(false);

        public static T Read<T>(string path) where T : class
        {
            if (!File.Exists(path)) return null;
            var text = File.ReadAllText(path);   // handles the BOM PowerShell writes
            if (string.IsNullOrWhiteSpace(text)) return null;
            return JsonSerializer.Deserialize<T>(text, Options);
        }

        // A JSON list that PowerShell may have written as a single object (or null).
        public static List<T> ReadList<T>(string path)
        {
            var list = new List<T>();
            if (!File.Exists(path)) return list;
            var text = File.ReadAllText(path);
            if (string.IsNullOrWhiteSpace(text)) return list;
            using var doc = JsonDocument.Parse(text, new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
            if (doc.RootElement.ValueKind == JsonValueKind.Array)
            {
                foreach (var e in doc.RootElement.EnumerateArray())
                    if (e.ValueKind == JsonValueKind.Object) list.Add(e.Deserialize<T>(Options));
            }
            else if (doc.RootElement.ValueKind == JsonValueKind.Object) list.Add(doc.RootElement.Deserialize<T>(Options));
            return list;
        }

        // Writes to a temp file first, so a crash mid-write never leaves a half-written file.
        public static void Write(string path, object value)
        {
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(value, value.GetType(), Options), Utf8);
            File.Move(tmp, path, true);
        }
    }

    // A list PowerShell may have written as one bare value instead of a one-item array.
    public sealed class FlexListConverter<T> : JsonConverter<List<T>>
    {
        public override List<T> Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            var list = new List<T>();
            if (reader.TokenType == JsonTokenType.Null) return list;
            if (reader.TokenType == JsonTokenType.StartArray)
            {
                while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
                {
                    if (reader.TokenType == JsonTokenType.Null) continue;
                    list.Add(JsonSerializer.Deserialize<T>(ref reader, options));
                }
                return list;
            }
            list.Add(JsonSerializer.Deserialize<T>(ref reader, options));
            return list;
        }

        public override void Write(Utf8JsonWriter writer, List<T> value, JsonSerializerOptions options)
        {
            writer.WriteStartArray();
            foreach (var item in value ?? new List<T>()) JsonSerializer.Serialize(writer, item, options);
            writer.WriteEndArray();
        }
    }
}
