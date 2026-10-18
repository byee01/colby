using System.Collections;
using System.Runtime.CompilerServices;

namespace Combustion.Core;

/// <summary>Collection-expression builder for <see cref="ValueList{T}"/>.</summary>
public static class ValueList
{
    public static ValueList<T> Create<T>(ReadOnlySpan<T> items) => new(items.ToArray());
}

/// <summary>Immutable list with structural equality, so records that hold lists compare by value (Swift arrays do).</summary>
[CollectionBuilder(typeof(ValueList), nameof(ValueList.Create))]
public sealed class ValueList<T> : IReadOnlyList<T>, IEquatable<ValueList<T>>
{
    private readonly T[] _items;

    public ValueList(IEnumerable<T> items)
    {
        _items = items.ToArray();
    }

    public static ValueList<T> Empty { get; } = new([]);

    public T this[int index] => _items[index];

    public int Count => _items.Length;

    public IEnumerator<T> GetEnumerator() => ((IEnumerable<T>)_items).GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => _items.GetEnumerator();

    public bool Equals(ValueList<T>? other) =>
        other is not null && (ReferenceEquals(this, other) || _items.AsSpan().SequenceEqual(other._items, EqualityComparer<T>.Default));

    public override bool Equals(object? obj) => obj is ValueList<T> other && Equals(other);

    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (var item in _items)
        {
            h.Add(item);
        }
        return h.ToHashCode();
    }

    public override string ToString() => "[" + string.Join(", ", _items) + "]";

    public static bool operator ==(ValueList<T>? a, ValueList<T>? b) => a is null ? b is null : a.Equals(b);

    public static bool operator !=(ValueList<T>? a, ValueList<T>? b) => !(a == b);

    public static implicit operator ValueList<T>(T[] items) => new(items);

    public static implicit operator ValueList<T>(List<T> items) => new(items);
}

/// <summary>Immutable dictionary with structural equality.</summary>
public sealed class ValueMap<TKey, TValue> : IReadOnlyDictionary<TKey, TValue>, IEquatable<ValueMap<TKey, TValue>>
    where TKey : notnull
{
    private readonly Dictionary<TKey, TValue> _items;

    public ValueMap(IEnumerable<KeyValuePair<TKey, TValue>> items)
    {
        _items = new Dictionary<TKey, TValue>(items);
    }

    public static ValueMap<TKey, TValue> Empty { get; } = new([]);

    public TValue this[TKey key] => _items[key];

    public IEnumerable<TKey> Keys => _items.Keys;

    public IEnumerable<TValue> Values => _items.Values;

    public int Count => _items.Count;

    public bool ContainsKey(TKey key) => _items.ContainsKey(key);

    public bool TryGetValue(TKey key, out TValue value) => _items.TryGetValue(key, out value!);

    public IEnumerator<KeyValuePair<TKey, TValue>> GetEnumerator() => _items.GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => _items.GetEnumerator();

    public bool Equals(ValueMap<TKey, TValue>? other)
    {
        if (other is null || other.Count != Count)
        {
            return false;
        }
        foreach (var (k, v) in _items)
        {
            if (!other._items.TryGetValue(k, out var ov) || !EqualityComparer<TValue>.Default.Equals(v, ov))
            {
                return false;
            }
        }
        return true;
    }

    public override bool Equals(object? obj) => obj is ValueMap<TKey, TValue> other && Equals(other);

    public override int GetHashCode()
    {
        var h = 0;
        foreach (var (k, v) in _items)
        {
            h ^= HashCode.Combine(k, v);
        }
        return h;
    }

    public static implicit operator ValueMap<TKey, TValue>(Dictionary<TKey, TValue> items) => new(items);
}

/// <summary>Immutable set with structural equality.</summary>
public sealed class ValueSet<T> : IReadOnlySet<T>, IEquatable<ValueSet<T>>
{
    private readonly HashSet<T> _items;

    public ValueSet(IEnumerable<T> items)
    {
        _items = new HashSet<T>(items);
    }

    public static ValueSet<T> Empty { get; } = new([]);

    public int Count => _items.Count;

    public bool Contains(T item) => _items.Contains(item);

    public bool IsProperSubsetOf(IEnumerable<T> other) => _items.IsProperSubsetOf(other);
    public bool IsProperSupersetOf(IEnumerable<T> other) => _items.IsProperSupersetOf(other);
    public bool IsSubsetOf(IEnumerable<T> other) => _items.IsSubsetOf(other);
    public bool IsSupersetOf(IEnumerable<T> other) => _items.IsSupersetOf(other);
    public bool Overlaps(IEnumerable<T> other) => _items.Overlaps(other);
    public bool SetEquals(IEnumerable<T> other) => _items.SetEquals(other);

    public IEnumerator<T> GetEnumerator() => _items.GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => _items.GetEnumerator();

    public bool Equals(ValueSet<T>? other) => other is not null && _items.SetEquals(other._items);

    public override bool Equals(object? obj) => obj is ValueSet<T> other && Equals(other);

    public override int GetHashCode()
    {
        var h = 0;
        foreach (var item in _items)
        {
            h ^= item?.GetHashCode() ?? 0;
        }
        return h;
    }

    public static implicit operator ValueSet<T>(HashSet<T> items) => new(items);
}
