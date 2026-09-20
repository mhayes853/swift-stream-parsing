# NoLifetimeSmoke

Builds and runs a real `@StreamParseable` expansion from a consumer target that enables neither
the `LifetimeView` package trait nor the experimental `Lifetimes` and `AddressableTypes` compiler
features. Its use of the default pointer-backed view is explicitly acknowledged with `unsafe`.

```sh
swift run --package-path NoLifetimeSmoke
```
