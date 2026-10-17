# O-SQL parser and source AST

[Specification](README.md) · [BNF](grammar.bnf) · [Typing](typing.md) · [Examples](examples.md)

The implementation is in [OSQL.Syntax](../../src/OSQL/Syntax.hs) and
[OSQL.Parser](../../src/OSQL/Parser.hs). Both are exposed by the ontology-language
Cabal library. It uses Megaparsec and the same String-based source convention as
the existing ontology parser. No SQL schema, database connection or ontology
instance is needed to parse a query.

## API and command line

```haskell
parseProgram     :: FilePath -> String -> Either ParseError Program
parseProgramFile :: FilePath -> IO (Either ParseError Program)
parseExpression  :: FilePath -> String -> Either ParseError Expr
renderParseError :: ParseError -> String
```

ParseError is a Megaparsec error bundle; renderParseError produces a source
excerpt, filename, line and column. File IO errors remain IO exceptions.

From the repository root:

```sh
cabal run osql-parse -- docs/o-sql/examples/complex-roles.osql
cabal test ontology-language:osql-parser-test
make test
```

The CLI prints the source AST and locations. A malformed source exits nonzero
with a readable diagnostic. It does not resolve objects, execute a query or
emit SQL.

## Representation

Program contains ordered top-level Binding values and one final Expr. Query
contains a Selection mode, Projection, nonempty source list and ordered steps:

```haskell
data Selection = AllResults | SingleResult

data Existence = NonEmptyResult | UniqueResult

data Arguments
  = Positional Expr
  | Named (NonEmpty (Name, Expr))
```

`select` uses AllResults; `select!` uses SingleResult. `exists(query)` uses
NonEmptyResult; `exist!(query)` and its `exists!` alias use UniqueResult. These
are syntactic modes. The existence node takes an Expr, allowing either a query
or a variable holding its set result. The [checker and PostgreSQL compiler](compiler.md) supply their
types and cardinality behavior. The parser never verifies that there is one answer.

Every expression has a source span. Expressions retain postfix heads/suffixes,
groups, selection, negation and binary operators. A postfix expression has one
Primary and a flat list of literal-field, optional-field and call suffixes.
Primary does not contain grouped expressions, so parentheses cannot acquire a
field or call suffix. Parentheses may still group Boolean expressions and
nested queries. Computed labels/indexed attributes are not syntax constructors.

```text
a?.b.c       -> primary a; suffixes [OptionalField b, Field c]
(a?.b).c     -> syntax error
let x = a?.b; x.c -> two expressions linked by a top-level binding
```

Match has either a nonempty list of named arms with an optional final fallback,
or one default-only expression. Each named arm keeps its branch label, payload
binder and unrestricted result expression. The AST imposes no shared result
type and adds no output discriminator.

Record fields, projection fields and named arguments are ordered lists, retaining
duplicates for later diagnostics. Source names do not carry caller-invented
ontology owner/result signatures, node IDs or storage table names. Root and
variable references remain distinct constructors.

## Lexical and source details

Decimal values retain an arbitrary-precision Integer coefficient and Integer
base-ten exponent. Parsing never converts to Double, allocates a power of ten,
or silently truncates the exponent. Timestamp constructors retain decoded text;
date/offset validation belongs to checking.

Strings use JSON escapes, including decoding a valid surrogate pair into one
Unicode scalar. Unpaired surrogates, U+0000, raw control characters and non-JSON
escapes are rejected. Unicode identifiers use letters, underscores and decimal
digits; reserved words can label fields/arguments/projections but cannot bind
variables. The standalone underscore belongs to the match fallback.

Locations include file, zero-based character offsets and one-based line/column
positions. Span ends are exclusive and may include following whitespace or line
comments consumed by the lexeme parser. They cover the source occurrence rather
than an identifier's semantic identity. Tabs follow Megaparsec's column rules.

## Parser/checker boundary

The parser enforces structure: explicit source aliases, named multi-projections,
nonempty argument lists, final fallback placement, precedence, grouping,
statement delimiters and literal-label navigation. It rejects `limit`, computed
field access and postfix operations on parenthesized expressions.

It deliberately preserves unknown names/fields/branches, duplicate names,
incomplete coverage, inappropriate operand types and conflicting declaration
bindings. Those are handled by the ontology-aware query checker. For example,
`exist!(select! p from root.people as p)` parses with both modes intact, then
requires a type diagnostic if the single selection returns a Person rather than
a Set. `exist!(people)` is valid when people is a bound Set. No claim of static validation is
made merely because a source parsed.

The existing Information checker implements another initial information AST.
Connecting checked O-SQL selections to questions, quotation and cognitive
contents remains an integration task. No second ontology or runtime object
store is introduced by these source types.

## Checks

The [parser suite](../../test/OSQLMain.hs) parses every complete `.osql` example,
checks positive/negative syntax, and inspects AST structure for precedence,
cardinality modes, ordered/nested bindings, heterogeneous arms and optional
chains. It also checks exact decimals, JSON escapes, Unicode and diagnostics.
The shared unit entry point runs it with warnings as errors and smoke-tests the
CLI on the complex roles query. This verifies parsing; hand-written result
types and simulation traces remain separate evidence.

