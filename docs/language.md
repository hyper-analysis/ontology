# Language reference

Ontology has its own syntax and semantics; the type-like notation is not TypeScript.

## Current surface operators

```text
type Name = T;

{ field: T; optional?: T; }     object
{ key field: T; }                explicit semantic-key component
Ref<Person>                      identity reference to a keyed object
T[]                              set; equal values cannot coexist
unique T[]                       same set semantics, retained surface form
unique(field) T[]                set plus stronger selector uniqueness
unique T                         integrity uniqueness, not semantic identity
(key: K) => V                   map / partial function with named argument
(a: A, b: B) => V               multi-key map
A & B                           object-field composition only
"a" | "b" | 1 | 2              scalar literal enumeration
alternative role {
  Student: Student;
  Teacher: Teacher;
}                               named ontological distinction
```

Primitives are `string`, `number`, `boolean`, and `timestamp`.

## Canonicalization and checks

The checker deliberately reduces the language further:

- intersections are allowed only when every component resolves to an object; they are
  merged into one record node;
- repeated fields in an intersection must have the same type; required overrides optional;
- raw unions are allowed only for scalar literal enumerations;
- entity/object alternatives must use the explicit `alternative <tag> {...}` form;
- every alternative branch must point to a named type;
- references target names only; reference refinements do not exist;
- function/map parameters must be named and key-like;
- a collection of functions/maps is rejected;
- a function/map directly returning a collection is rejected;
- nested maps are rejected in favor of one map with multiple named parameters;
- selector-based collection uniqueness must name a required field present in every
  branch of an alternative;
- value recursion is rejected; recursive/shared structure must pass through `Ref`;
- the root is an object whose fields are collections.

Common fields of alternative branches are **not** factored outward. Branch structure is
kept exactly as authored.


### Identity and keyability

Identity is declared, not inferred. At an object boundary, only immediate fields marked
`key` contribute to that object's semantic key. A marked field contributes its **whole
value**. Key annotations nested inside that selected value do not narrow it, and keys
inside an unmarked named/by-value field never bubble upward.

`key` and `unique` are different: a key is part of semantic addressability and implies
the corresponding population must be unique; `unique` is only an integrity constraint.

Semantic keys and map arguments must be finite **Keyable** values: scalars/literals,
references to keyed objects, or required records recursively composed from Keyable
values. Collections, maps, and alternatives are not Keyable. Therefore a collection-valued
key and a set of values containing relational children are rejected.

Every ordinary `T[]` is a set. Its member discriminator is the complete Keyable value of
`T`; the compiler does not invent a semantic occurrence number. If individually
addressable duplicate-looking values are required, model the collection as a map with an
explicit discriminator.

Root populations and every target of `Ref<T>` must be named keyed objects. PostgreSQL
may still use generated surrogate IDs internally, but those IDs are storage identity and
are not part of the ontology's semantic address.


