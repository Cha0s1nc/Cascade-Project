using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using MediaBrowser.Common.Configuration;

namespace Jellyfin.Plugin.CascadeServer.LyricStore;

/// <summary>
/// A small JSON file of Guid-keyed entries in the data dir, in the shape of
/// <see cref="SpotifyIdStore"/>: loaded lazily into a <see cref="ConcurrentDictionary{TKey,TValue}"/>,
/// written to a .tmp file and moved into place.
/// </summary>
/// <typeparam name="T">The entry type.</typeparam>
public sealed class JsonStore<T>
    where T : class
{
    private readonly string _fileName;
    private readonly object _fileLock = new();
    private ConcurrentDictionary<Guid, T>? _entries;
    private string? _path;

    /// <summary>Initialises a new instance of <see cref="JsonStore{T}"/>.</summary>
    /// <param name="fileName">File name inside the data dir.</param>
    public JsonStore(string fileName)
    {
        _fileName = fileName;
    }

    /// <summary>The entry, or <c>null</c> when there is none.</summary>
    public T? Get(IApplicationPaths appPaths, Guid id)
        => Load(appPaths).TryGetValue(id, out var e) ? e : null;

    /// <summary>Stores the entry and writes the file.</summary>
    public void Set(IApplicationPaths appPaths, Guid id, T entry)
    {
        Load(appPaths)[id] = entry;
        Save();
    }

    /// <summary>Forgets the entry.</summary>
    public void Remove(IApplicationPaths appPaths, Guid id)
    {
        if (Load(appPaths).TryRemove(id, out _)) Save();
    }

    /// <summary>A snapshot of every entry.</summary>
    public List<KeyValuePair<Guid, T>> All(IApplicationPaths appPaths) => [.. Load(appPaths)];

    private ConcurrentDictionary<Guid, T> Load(IApplicationPaths appPaths)
    {
        if (_entries is not null) return _entries;
        lock (_fileLock)
        {
            if (_entries is not null) return _entries;
            _path = Path.Combine(DataDir.Root(appPaths), _fileName);
            var loaded = new ConcurrentDictionary<Guid, T>();
            try
            {
                if (File.Exists(_path))
                {
                    var raw = JsonSerializer.Deserialize<Dictionary<Guid, T>>(File.ReadAllText(_path));
                    foreach (var (k, v) in raw ?? []) if (v is not null) loaded[k] = v;
                }
            }
            catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
            {
                // Unreadable: start empty. Worst case every item is looked up again.
            }

            _entries = loaded;
            return _entries;
        }
    }

    private void Save()
    {
        lock (_fileLock)
        {
            if (_entries is null || _path is null) return;
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(new Dictionary<Guid, T>(_entries)));
            File.Move(tmp, _path, overwrite: true);
        }
    }
}
