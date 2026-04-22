# MetaModelica Syntax Reference

This document describes the syntactic constructs that are specific to
MetaModelica — the language extension used to implement OpenModelica. Use it
alongside `search_codebase`, `lookup_symbol`, and `fuzzy_lookup` to find patterns
in real source code.

---

## Uniontype

A `uniontype` is an algebraic data type. It groups named record constructors
under a common type.

```modelica
uniontype Shape
  record CIRCLE
    Real radius;
  end CIRCLE;
  record RECTANGLE
    Real width;
    Real height;
  end RECTANGLE;
end Shape;
```

Uniontypes are analogous to Haskell/OCaml `data` types or Rust `enum`s with
fields. Each constructor is a record and can be deconstructed with `match`.

Search query: `"uniontype record constructors"`

---

## match / matchcontinue

Pattern matching over values. `match` fails if no branch matches; `matchcontinue` tries the next branch on any failure.

```modelica
function area
  input Shape s;
  output Real a;
algorithm
  a := match s
    case CIRCLE(radius = r)       then 3.14159 * r * r;
    case RECTANGLE(width = w, height = h) then w * h;
  end match;
end area;
```

`matchcontinue` is used when branches should be tried in order with backtracking:

```modelica
function lookup
  input list<tuple<String, Integer>> env;
  input String key;
  output Integer val;
algorithm
  val := matchcontinue env
    local String k; Integer v; list<tuple<String, Integer>> rest;
    case ((k, v) :: _)    guard stringEqual(k, key) then v;
    case (_ :: rest)       then lookup(rest, key);
    case {}                then fail();
  end matchcontinue;
end lookup;
```

Search query: `"matchcontinue backtracking list"`

---

## list\<T\>

Persistent singly-linked lists. Constructed with `::` (cons) and `{}` (nil).

```modelica
list<Integer> xs = {1, 2, 3};         // literal
list<Integer> ys = 0 :: xs;           // cons: {0, 1, 2, 3}
```

Common list operations (from `List` package in OpenModelica):

| Function | Description |
|----------|-------------|
| `listLength(lst)` | Number of elements |
| `listAppend(a, b)` | Concatenate two lists |
| `listReverse(lst)` | Reverse a list |
| `listHead(lst)` | First element (fails on empty) |
| `listRest(lst)` | Tail (fails on empty) |
| `listGet(lst, n)` | n-th element (1-indexed) |

Pattern matching on lists:

```modelica
match lst
  case {}       then "empty";
  case x :: {}  then "singleton";
  case x :: rest then "head is " + String(x);
end match;
```

Search query: `"list cons pattern match head tail"`

---

## Option\<T\>

Optional values with two constructors: `SOME(value)` and `NONE()`.

```modelica
Option<Real> maybeVal = SOME(3.14);
Option<Real> nothing  = NONE();

function unwrapOr
  input Option<Real> opt;
  input Real default_;
  output Real result;
algorithm
  result := match opt
    case SOME(v) then v;
    case NONE()  then default_;
  end match;
end unwrapOr;
```

Search query: `"Option SOME NONE match"`

---

## array\<T\>

Mutable zero-indexed arrays. Different from `list<T>` (which is persistent).

```modelica
array<Integer> arr = arrayCreate(5, 0);   // [0,0,0,0,0]
arrayUpdate(arr, 1, 42);                   // arr[1] := 42  (1-indexed)
Integer v = arrayGet(arr, 1);             // 42
Integer n = arrayLength(arr);             // 5
```

Arrays cannot be pattern-matched; use index access and loops.

Search query: `"arrayCreate arrayUpdate arrayGet"`

---

## tuple\<T1, T2, ...\>

Unnamed product types. Constructed with parentheses:

```modelica
tuple<String, Integer> pair = ("hello", 42);
(String s, Integer n) = pair;   // destructure
```

In match expressions:

```modelica
match pair
  case (s, n) then n;
end match;
```

Search query: `"tuple destructure match"`

---

## fail()

Explicit failure — causes the current `matchcontinue` branch to be abandoned,
or propagates out of a `match` as a runtime error.

```modelica
function safeDiv
  input Integer a;
  input Integer b;
  output Integer result;
algorithm
  result := matchcontinue (a, b)
    case (_, 0) then fail();   // do not divide by zero
    case (x, y) then intDiv(x, y);
  end matchcontinue;
end safeDiv;
```

`fail()` is also used in `matchcontinue` guards to force the next branch:

```modelica
case x guard x < 0 then fail();   // try next branch for negative x
```

Search query: `"fail matchcontinue guard"`

---

## equality()

Assert structural equality between two values. Fails if they differ. Commonly
used as a guard in `matchcontinue`.

```modelica
matchcontinue (x, y)
  case (a, b) equation equality(a, b); then "equal";
  case _                                then "not equal";
end matchcontinue;
```

---

## Local variable declarations in match

Variables introduced in a match branch are declared with `local`:

```modelica
match expr
  local
    Integer n;
    String s;
  case SOME(n) then intString(n);
  case NONE()  then "nothing";
end match;
```

---

## String operations

Key built-in string functions:

| Function | Description |
|----------|-------------|
| `stringEqual(a, b)` | Structural string equality (preferred over `==`) |
| `stringAppend(a, b)` | Concatenate (also `a + b`) |
| `stringLength(s)` | Number of characters |
| `intString(n)` | Integer to string |
| `realString(r)` | Real to string |
| `stringInt(s)` | String to integer |
| `stringChar(s, n)` | n-th character |
| `stringListStringChar(s)` | Explode to `list<String>` |

Search query: `"stringEqual stringAppend intString"`

---

## Differences from standard Modelica

| Feature | Standard Modelica | MetaModelica |
|---------|------------------|--------------|
| Tagged unions | No | `uniontype` |
| Pattern matching | No | `match` / `matchcontinue` |
| Linked lists | No | `list<T>` |
| Optional values | No | `Option<T>` |
| Explicit failure | No | `fail()` |
| Higher-order functions | Limited | Yes (function references) |
| Mutable arrays | `array[n]` syntax | `array<T>` with API |
