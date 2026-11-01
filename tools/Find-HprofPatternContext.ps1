param(
    [Parameter(Mandatory = $true)]
    [string] $Path,

    [string[]] $Patterns = @("nitrite", "Nitrite", "org.dizitart", "org/dizitart", "MVStore", ".mv.db", ".db", "filePath"),

    [int] $Context = 220,

    [int] $MaxResultsPerPattern = 80
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public sealed class HprofPatternScanner
{
    public sealed class Result
    {
        public string Pattern;
        public long Offset;
        public string Text;
    }

    public static List<Result> Scan(string path, string[] patterns, int context, int maxResultsPerPattern)
    {
        var encoded = new List<Tuple<string, byte[]>>();
        foreach (var pattern in patterns)
        {
            encoded.Add(Tuple.Create(pattern, Encoding.ASCII.GetBytes(pattern.ToLowerInvariant())));
        }

        var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var results = new List<Result>();
        int bufferSize = 16 * 1024 * 1024;
        int overlap = Math.Max(context * 2 + 1024, 8192);
        byte[] buffer = new byte[bufferSize + overlap];

        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            int carry = 0;
            long baseOffset = 0;
            while (true)
            {
                int read = stream.Read(buffer, carry, bufferSize);
                if (read <= 0) break;

                int length = carry + read;
                byte[] lower = new byte[length];
                for (int i = 0; i < length; i++)
                {
                    byte b = buffer[i];
                    lower[i] = (b >= 65 && b <= 90) ? (byte)(b + 32) : b;
                }

                foreach (var item in encoded)
                {
                    string pattern = item.Item1;
                    byte[] needle = item.Item2;
                    if (!counts.ContainsKey(pattern)) counts[pattern] = 0;
                    if (counts[pattern] >= maxResultsPerPattern) continue;

                    for (int i = 0; i <= length - needle.Length; i++)
                    {
                        bool match = true;
                        for (int j = 0; j < needle.Length; j++)
                        {
                            if (lower[i + j] != needle[j])
                            {
                                match = false;
                                break;
                            }
                        }
                        if (!match) continue;

                        int start = Math.Max(0, i - context);
                        int end = Math.Min(length, i + needle.Length + context);
                        string text = Printable(buffer, start, end - start);
                        string key = pattern + "\t" + text;
                        if (seen.Add(key))
                        {
                            results.Add(new Result {
                                Pattern = pattern,
                                Offset = baseOffset + i - carry,
                                Text = text
                            });
                            counts[pattern]++;
                            if (counts[pattern] >= maxResultsPerPattern) break;
                        }
                    }
                }

                carry = Math.Min(overlap, length);
                Buffer.BlockCopy(buffer, length - carry, buffer, 0, carry);
                baseOffset = stream.Position - carry;
            }
        }

        return results;
    }

    private static string Printable(byte[] buffer, int start, int count)
    {
        var sb = new StringBuilder(count);
        bool lastWasSpace = false;
        for (int i = start; i < start + count; i++)
        {
            byte b = buffer[i];
            char c = (b >= 32 && b <= 126) ? (char)b : ' ';
            if (c == ' ')
            {
                if (!lastWasSpace)
                {
                    sb.Append(c);
                    lastWasSpace = true;
                }
            }
            else
            {
                sb.Append(c);
                lastWasSpace = false;
            }
        }
        return sb.ToString().Trim();
    }
}
"@

$resolved = Resolve-Path -LiteralPath $Path
[HprofPatternScanner]::Scan($resolved.Path, $Patterns, $Context, $MaxResultsPerPattern) |
    ForEach-Object {
        [pscustomobject]@{
            Pattern = $_.Pattern
            Offset = $_.Offset
            Text = $_.Text
        }
    }
